package dev.pronto.autofill.asker;

import android.app.Activity;
import android.os.Bundle;
import android.text.Editable;
import android.text.TextWatcher;
import android.widget.EditText;
import android.widget.TextView;

// One login form, two fields that say what they are: the system's autofill reads the hints. The
// echo says what they hold ("username:password"), since a password field's text is masked on screen.
public class LoginActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.login);
        EditText username = findViewById(R.id.username);
        EditText password = findViewById(R.id.password);
        TextView echo = findViewById(R.id.echo);
        TextWatcher watcher = new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int a, int b, int c) {}
            @Override public void onTextChanged(CharSequence s, int a, int b, int c) {}
            @Override public void afterTextChanged(Editable e) {
                echo.setText(username.getText() + ":" + password.getText());
            }
        };
        username.addTextChangedListener(watcher);
        password.addTextChangedListener(watcher);
    }
}
