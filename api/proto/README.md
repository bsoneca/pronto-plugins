`google/api/annotations.proto` and `google/api/http.proto`, unchanged from
[googleapis](https://github.com/googleapis/googleapis) at commit
8f28f48bf9ea3ec0f14a75a5cfc970819cec9e2b (Apache-2.0, their headers kept). `generate.ts` builds every
app's .proto beside them, so `buf build` needs no registry or network.
