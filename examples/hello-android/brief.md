# Hello Android

A counter that runs the same program in the browser and as a native Android
app, with no WebView: the first app on pronto's Android host.

## Data

One counter, from −99 to 99, starting at zero.

## Screens

- **Counter** — two buttons step the number.

## Behavior

Everything happens on the reader's device. The browser and the phone run the
same handler file, caged by SES in each, so the same presses give the same
number on both.

![[acceptance]]

## Out of scope

Keeping the count across a restart, syncing it between devices, and any
screen beyond the counter.
