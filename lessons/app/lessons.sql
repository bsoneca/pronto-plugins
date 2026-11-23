SET lock_timeout = '5s';
SET statement_timeout = '30s';
-- pronto-lessons' functions (lessons/README.md, "L2"): the player's whole write path. A raw migration, replayed at every
-- release: a function whose signature changes is dropped before it is created.
--
-- Every function that a session can call is SECURITY DEFINER with a pinned search_path (pg_catalog, then pg_temp last: no
-- schema of the app's can shadow a name) and qualifies every relation and function; EXECUTE goes to app_user alone, never anon, never PUBLIC. Who is asked of the session
-- (public.auth_uid()), never of an argument, so nobody plays as another. The tables are written by these functions
-- only (the lesson_progress_read_only trigger, lessons_plugin.cue).
-- The courses are read from lessons.spec() (the generated _lessonsOut.sql), the prices from the app's hooks
-- lessons_app.price, pay and reward.

CREATE SCHEMA IF NOT EXISTS lessons;
REVOKE ALL ON SCHEMA lessons FROM PUBLIC;

-- The ply a script's replies are played to: the next at or after `p_step` that the player moves (the player moves
-- the plies p_step % 2 = p_player), or the end.
DROP FUNCTION IF EXISTS lessons.advance(int, int, int);
CREATE FUNCTION lessons.advance(p_step int, p_len int, p_player int) RETURNS int
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, pg_temp AS $f$
DECLARE s int := p_step;
BEGIN
  WHILE s < p_len AND s % 2 <> p_player LOOP
    s := s + 1;
  END LOOP;
  RETURN s;
END $f$;
REVOKE ALL ON FUNCTION lessons.advance(int, int, int) FROM PUBLIC;

-- A row as the page reads it.
DROP FUNCTION IF EXISTS lessons.view(public.lesson_progress, int);
CREATE FUNCTION lessons.view(r public.lesson_progress, n int) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, pg_temp AS $f$
  SELECT jsonb_build_object('course', r.course, 'chapter', r.chapter, 'part', r.part, 'step', r.step,
    'wrongs', r.wrongs, 'step_wrongs', r.step_wrongs, 'pool_said', r.pool_said, 'hinted', r.hinted,
    'done', r.done, 'over', r.step >= n)
$f$;
REVOKE ALL ON FUNCTION lessons.view(public.lesson_progress, int) FROM PUBLIC;

-- One entry through the ledger: a row goes in first, and the app's hook is called only when it did, so an entry is
-- settled once whatever the hook does with a second call. A hook that raises (short of gold) takes the ledger row
-- with it: the same transaction. An entry of nothing is recorded and settled with no call.
DROP FUNCTION IF EXISTS lessons.settle(uuid, text, text, int);
CREATE FUNCTION lessons.settle(p_who uuid, p_entry text, p_kind text, p_amount int) RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $f$
DECLARE added int;
BEGIN
  INSERT INTO lessons.paid (owner, entry, kind, amount) VALUES (p_who, p_entry, p_kind, p_amount)
    ON CONFLICT (owner, entry) DO NOTHING RETURNING 1 INTO added;
  IF added IS NULL OR p_amount <= 0 THEN
    RETURN;
  END IF;
  IF p_kind IN ('open', 'hint') THEN
    PERFORM lessons_app.pay(p_who, p_entry, p_amount);
  ELSE
    PERFORM lessons_app.reward(p_who, p_entry, p_amount);
  END IF;
END $f$;
REVOKE ALL ON FUNCTION lessons.settle(uuid, text, text, int) FROM PUBLIC;

-- The read-only gates, in their order, for the three functions: who, which chapter, whether it is on for them, and
-- whether their plan may open lessons. Returns {who, course, pi, ci, price} (the part's and the chapter's place,
-- from 0). Nothing is charged here.
DROP FUNCTION IF EXISTS lessons.gate(text, text);
CREATE FUNCTION lessons.gate(p_course text, p_chapter text) RETURNS jsonb
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $f$
DECLARE
  v_who uuid := public.auth_uid();
  v_claim text := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'guest';
  v_course jsonb;
  v_price int;
  v_pi int;
  v_ci int;
BEGIN
  -- A guest claim is read as text and anything but an explicit false counts: a claim that is no boolean is a refusal too.
  IF v_who IS NULL OR (v_claim IS NOT NULL AND v_claim <> 'false') THEN
    RAISE EXCEPTION 'lessons: a guest has no lessons' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_course IS NULL OR p_chapter IS NULL OR char_length(p_course) > 64 OR char_length(p_chapter) > 64 THEN
    RAISE EXCEPTION 'lessons: no such chapter' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  v_course := lessons.spec() -> 'courses' -> p_course;
  IF v_course IS NULL THEN
    RAISE EXCEPTION 'lessons: no such chapter' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF NOT coalesce(pronto_flags.flag_on_strict(v_course ->> 'flag', v_who), false) THEN
    RAISE EXCEPTION 'lessons: unavailable' USING ERRCODE = 'insufficient_privilege';
  END IF;
  v_price := lessons_app.price(v_who);
  IF v_price IS NULL OR v_price < 0 THEN
    RAISE EXCEPTION 'lessons: not for this plan' USING ERRCODE = 'insufficient_privilege';
  END IF;
  SELECT p.i - 1, ch.j - 1 INTO v_pi, v_ci
    FROM jsonb_array_elements(v_course -> 'parts') WITH ORDINALITY AS p(part, i),
         jsonb_array_elements(p.part -> 'chapters') WITH ORDINALITY AS ch(chapter, j)
    WHERE ch.chapter ->> 'id' = p_chapter;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'lessons: no such chapter' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  RETURN jsonb_build_object('who', v_who, 'course', v_course, 'pi', v_pi, 'ci', v_ci, 'price', v_price);
END $f$;
REVOKE ALL ON FUNCTION lessons.gate(text, text) FROM PUBLIC;

-- Open a chapter: a new row at the first ply the player moves, or a finished chapter played again (the counters and the
-- hint reset, `done` kept), or the row of one in progress as it is. A chapter after another's end is locked until
-- that is done. Charged last, once, at the tier's price.
DROP FUNCTION IF EXISTS public.lesson_start(text, text);
CREATE FUNCTION public.lesson_start(course text, chapter text) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $f$
#variable_conflict use_variable
DECLARE
  g jsonb := lessons.gate(course, chapter);
  v_who uuid := (g ->> 'who')::uuid;
  v_pi int := (g ->> 'pi')::int;
  v_ci int := (g ->> 'ci')::int;
  v_part jsonb := g -> 'course' -> 'parts' -> v_pi;
  v_ch jsonb := v_part -> 'chapters' -> v_ci;
  v_n int := jsonb_array_length(v_ch -> 'moves');
  v_player int := (v_part ->> 'player')::int;
  v_id text := v_who::text || '/' || course || '/' || chapter;
  v_need jsonb;
  v_first int;
  v_new boolean;
  r public.lesson_progress;
BEGIN
  -- Locked: the chapter before it in its part, or, for a part's first, every chapter of the part before.
  IF v_ci > 0 THEN
    v_need := jsonb_build_array(v_part -> 'chapters' -> (v_ci - 1));
  ELSIF v_pi > 0 THEN
    v_need := g -> 'course' -> 'parts' -> (v_pi - 1) -> 'chapters';
  END IF;
  IF v_need IS NOT NULL AND EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_need) AS n
    WHERE NOT EXISTS (
      SELECT 1 FROM public.lesson_progress lp
      WHERE lp.owner_id = v_who AND lp.id = v_who::text || '/' || course || '/' || (n ->> 'id') AND lp.done)
  ) THEN
    RAISE EXCEPTION 'lessons: locked' USING ERRCODE = 'check_violation';
  END IF;

  v_first := lessons.advance((v_ch ->> 'shown')::int, v_n, v_player);
  INSERT INTO public.lesson_progress (id, course, chapter, part, step, wrongs, step_wrongs, pool_said, hinted, done, updated, owner_id)
    VALUES (v_id, course, chapter, v_part ->> 'id', v_first, 0, 0, 0, -1, false, now(), v_who)
    ON CONFLICT (id) DO NOTHING;
  v_new := FOUND;
  SELECT * INTO r FROM public.lesson_progress lp WHERE lp.id = v_id AND lp.owner_id = v_who FOR UPDATE;
  IF NOT v_new AND r.step >= v_n THEN
    UPDATE public.lesson_progress lp
      SET step = v_first, wrongs = 0, step_wrongs = 0, pool_said = 0, hinted = -1, updated = now()
      WHERE lp.id = v_id
      RETURNING * INTO r;
  END IF;
  PERFORM lessons.settle(v_who, 'lesson/' || course || '/' || chapter || '/open', 'open', (g ->> 'price')::int);
  RETURN lessons.view(r, v_n)::json;
END $f$;
REVOKE ALL ON FUNCTION public.lesson_start(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.lesson_start(text, text) TO app_user;

-- A move at `step`: judged by the token's equality with the script's. A move at any other step, after the end, or past a
-- script since shortened, is a retry or a stale page and changes nothing: the row is returned for the page to adopt.
DROP FUNCTION IF EXISTS public.lesson_move(text, text, int, text);
CREATE FUNCTION public.lesson_move(course text, chapter text, step int, token text) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $f$
#variable_conflict use_variable
DECLARE
  g jsonb := lessons.gate(course, chapter);
  v_who uuid := (g ->> 'who')::uuid;
  v_part jsonb := g -> 'course' -> 'parts' -> (g ->> 'pi')::int;
  v_ch jsonb := v_part -> 'chapters' -> (g ->> 'ci')::int;
  v_moves jsonb := v_ch -> 'moves';
  v_n int := jsonb_array_length(v_moves);
  v_player int := (v_part ->> 'player')::int;
  v_id text := v_who::text || '/' || course || '/' || chapter;
  v_step int := step;
  v_next int;
  v_was_done boolean;
  v_own int;
  r public.lesson_progress;
BEGIN
  IF token IS NULL OR char_length(token) > 64 OR v_step IS NULL OR v_step < 0 THEN
    RAISE EXCEPTION 'lessons: bad move' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  -- The part's rows of the account, in id order, before this one: two moves finishing the part's last two chapters at
  -- once meet here, and the second sees the first's chapter done (so the bonus is paid by one of them, and no two
  -- moves wait on each other's rows).
  PERFORM 1 FROM public.lesson_progress lp
    WHERE lp.owner_id = v_who AND lp.course = course AND lp.part = v_part ->> 'id' ORDER BY lp.id FOR UPDATE;
  SELECT * INTO r FROM public.lesson_progress lp WHERE lp.id = v_id AND lp.owner_id = v_who FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'lessons: not started' USING ERRCODE = 'check_violation';
  END IF;
  IF v_step <> r.step OR r.step >= v_n THEN
    RETURN lessons.view(r, v_n)::json;
  END IF;

  IF token = v_moves ->> v_step THEN
    v_next := lessons.advance(v_step + 1, v_n, v_player);
    v_was_done := r.done;
    UPDATE public.lesson_progress lp
      SET step = v_next, step_wrongs = 0, done = lp.done OR v_next >= v_n, updated = now()
      WHERE lp.id = v_id
      RETURNING * INTO r;
    IF v_next >= v_n AND NOT v_was_done THEN
      PERFORM lessons.settle(v_who, 'lesson/' || course || '/' || chapter || '/done', 'done', (v_part ->> 'reward')::int);
      -- The part's last chapter: its bonus.
      IF NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_part -> 'chapters') AS pc
        WHERE NOT EXISTS (
          SELECT 1 FROM public.lesson_progress lp
          WHERE lp.owner_id = v_who AND lp.id = v_who::text || '/' || course || '/' || (pc ->> 'id') AND lp.done)
      ) THEN
        PERFORM lessons.settle(v_who, 'lesson/' || course || '/' || (v_part ->> 'id') || '/bonus', 'bonus', (v_part ->> 'bonus')::int);
      END IF;
    END IF;
  ELSE
    -- The page's own count (lessons.js pick): a wrong move past the ply's own lines says one of the part's pool.
    v_own := coalesce((v_ch -> 'own' ->> v_step::text)::int, 0);
    UPDATE public.lesson_progress lp
      SET wrongs = lp.wrongs + 1, step_wrongs = lp.step_wrongs + 1,
          pool_said = lp.pool_said + CASE WHEN lp.step_wrongs + 1 > v_own THEN 1 ELSE 0 END, updated = now()
      WHERE lp.id = v_id
      RETURNING * INTO r;
  END IF;
  RETURN lessons.view(r, v_n)::json;
END $f$;
REVOKE ALL ON FUNCTION public.lesson_move(text, text, int, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.lesson_move(text, text, int, text) TO app_user;

-- A hint at the step the lesson is at: its token, charged once an entry (a hint bought stays bought, a replay
-- included). A stale step or a finished chapter changes nothing and costs nothing.
DROP FUNCTION IF EXISTS public.lesson_hint(text, text, int);
CREATE FUNCTION public.lesson_hint(course text, chapter text, step int) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $f$
#variable_conflict use_variable
DECLARE
  g jsonb := lessons.gate(course, chapter);
  v_who uuid := (g ->> 'who')::uuid;
  v_moves jsonb := g -> 'course' -> 'parts' -> (g ->> 'pi')::int -> 'chapters' -> (g ->> 'ci')::int -> 'moves';
  v_n int := jsonb_array_length(v_moves);
  v_id text := v_who::text || '/' || course || '/' || chapter;
  v_step int := step;
  r public.lesson_progress;
BEGIN
  IF v_step IS NULL OR v_step < 0 THEN
    RAISE EXCEPTION 'lessons: bad step' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  SELECT * INTO r FROM public.lesson_progress lp WHERE lp.id = v_id AND lp.owner_id = v_who FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'lessons: not started' USING ERRCODE = 'check_violation';
  END IF;
  IF v_step <> r.step OR r.step >= v_n THEN
    RETURN lessons.view(r, v_n)::json;
  END IF;
  PERFORM lessons.settle(v_who, 'lesson/' || course || '/' || chapter || '/' || v_step, 'hint', (g -> 'course' -> 'hint' ->> 'price')::int);
  UPDATE public.lesson_progress lp SET hinted = v_step, updated = now() WHERE lp.id = v_id RETURNING * INTO r;
  RETURN (lessons.view(r, v_n) || jsonb_build_object('token', v_moves ->> v_step))::json;
END $f$;
REVOKE ALL ON FUNCTION public.lesson_hint(text, text, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.lesson_hint(text, text, int) TO app_user;

NOTIFY pgrst, 'reload schema';
