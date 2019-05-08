# fpc-lambda-runtime

This project is a sample implementation of a custom lambda runtime environment for Free Pascal.
It was developed using Lazarus 2.0.2 and FPC 3.0.4, but Lazarus is not required.

# Implementation

As the code currently stands, the application simply echoes back the input sent to it. You will
hopefully want to do something more productive, and as such, should modify the 
TLambdaRuntime.ProcessEvent() routine.

# Build

Using lazbuild:

```console
user@box:~/fpc-lambda-runtime$ lazbuild --build-mode=Release fpc-lambda-runtime.lpi
```

The executable should be named **bootstrap**.

# Deploy

See [Tutorial – Publishing a Custom Runtime](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-walkthrough.html)
