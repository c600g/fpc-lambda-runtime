program fpc_lambda_runtime;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
  {$ENDIF}{$ENDIF}
  Classes
  , CustApp
  , SysUtils
  { you can add units after this }
  , fphttpclient
  ;

const
  // AWS Environment Variable Names
  AWS_ENV_LAMBDA_TASK_ROOT = 'LAMBDA_TASK_ROOT';
  AWS_ENV_LAMBDA_HANDLER = '_HANDLER';
  AWS_ENV_LAMBDA_RUNTIME_API = 'AWS_LAMBDA_RUNTIME_API';

  // AWS Lambda API urls
  AWS_URL_LAMBDA_API_VERSION = '/2018-06-01';
  AWS_URL_LAMBDA_REQUEST_ID = '%%AwsRequestId%%';
  AWS_URL_LAMBDA_API_NEXT = '/runtime/invocation/next';
  AWS_URL_LAMBDA_API_RESPONSE = '/runtime/invocation/' + AWS_URL_LAMBDA_REQUEST_ID + '/response';
  AWS_URL_LAMBDA_API_ERROR = '/runtime/invocation/' + AWS_URL_LAMBDA_REQUEST_ID + '/error';
  AWS_URL_LAMBDA_API_INIT_ERROR = '/runtime/init/error';

  // AWS Lambda Header variables
  AWS_HDR_LAMBDA_REQUEST_ID = 'Lambda-Runtime-Aws-Request-Id';
  AWS_HDR_LAMBDA_DEADLIN_MS = 'Lambda-Runtime-Deadline-Ms';
  AWS_HDR_LAMBDA_FUNCTION_ARN = 'Lambda-Runtime-Invoked-Function-Arn';
  AWS_HDR_LAMBDA_TRACE_ID = 'Lambda-Runtime-Trace-Id';
  AWS_HDR_LAMBDA_CLIENT_CTX = 'Lambda-Runtime-Client-Context';
  AWS_HDR_LAMBDA_COGNITO_ID = 'Lambda-Runtime-Cognito-Identity';

type

  { TLambdaRuntime }

  TLambdaRuntime = class(TCustomApplication)
  protected
    _AwsLambdaPath    : string;  // Path where package was extracted, retrieved from environment variable.
    _AwsLambdaHandler : string;  // Name of the script handler, retrieved from environment variable.
    _AwsLambdaApi     : string;  // AWS Lambda Runtime API endpoint, retrieved from environment variable.
    _AwsApiVersion    : string;  // The API version, currently 2018-06-01.

    _AwsRequestId     : string;  // Lambda-Runtime-Aws-Request-Id - The request ID, which identifies the request that
                                 //   triggered the function invocation. EX: 8476a536-e9f4-11e8-9739-2dfe598c3fcd.
    _AwsDeadlineMs    : longint; // Lambda-Runtime-Deadline-Ms - The date that the function times out in Unix time
                                 //   milliseconds. EX: 1542409706888.
    _AwsFunctionArn   : string;  // Lambda-Runtime-Invoked-Function-Arn – The ARN of the Lambda function, version, or
                                 //   alias that's specified in the invocation.
    _AwsTraceId       : string;  // Lambda-Runtime-Trace-Id – The AWS X-Ray tracing header.
                                 //   EX: Root=1-5bef4de7-ad49b0e87f6ef6c87fc2e700;Parent=9a9197af755a6419;Sampled=1.
    _AwsClientContext : string;  // Lambda-Runtime-Client-Context – For invocations from the AWS Mobile SDK, data about
                                 //   the client application and device.
    _AwsCognitoId     : string;  // Lambda-Runtime-Cognito-Identity – For invocations from the AWS Mobile SDK, data
                                 //   about the Amazon Cognito identity provider.

    procedure DoRun; override;
    procedure ClearHeaders;
    procedure LambdaLoop;
    function GetEvent(out req : string; out req_content_type : string) : string;
    function ProcessEvent(const req : string; const req_content_type : string; out res : string; out res_content_type : string) : string;
    function SendResponse(const res : string; const res_content_type : string) : string;
    procedure SendError(err : string);
    procedure SendInitError(err : string);
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
  end;

{ TLambdaRuntime }

procedure TLambdaRuntime.DoRun;
var
  err : string;
begin
  // Initialize Lambda Environment
  err := '';

  try

    // get the lambda task path from an environment variable
    Self._AwsLambdaPath := GetEnvironmentVariable( AWS_ENV_LAMBDA_TASK_ROOT );
    if (Self._AwsLambdaPath = '') then
      err := 'Environment variable ' + AWS_ENV_LAMBDA_TASK_ROOT + ' not found.';

    // get the lambda handler from an environment variable
    Self._AwsLambdaHandler := GetEnvironmentVariable( AWS_ENV_LAMBDA_HANDLER );
    if (Self._AwsLambdaHandler = '') then
      err := 'Environment variable ' + AWS_ENV_LAMBDA_HANDLER + ' not found.';

    // get the lambda runtime API url from an environment variable
    Self._AwsLambdaApi := GetEnvironmentVariable( AWS_ENV_LAMBDA_RUNTIME_API );
    if (Self._AwsLambdaApi = '') then
      err := 'Environment variable ' + AWS_ENV_LAMBDA_RUNTIME_API + ' not found.';

    // set the API version
    Self._AwsApiVersion := AWS_URL_LAMBDA_API_VERSION;

    if (err = '') then begin
      LambdaLoop;
    end
    else begin
      if (Self._AwsLambdaApi <> '') then begin
        Self.SendInitError(err);
      end
      else begin
        writeln(stderr, err);
      end;
    end;

  except
    on E: Exception do begin
        writeln(stderr, 'Exception ' + E.ClassName + ' encountered. "' + E.Message +'"');
    end;
  end;

  // stop program loop
  Terminate;
end;

procedure TLambdaRuntime.ClearHeaders;
begin
  Self._AwsRequestId     := '';
  Self._AwsDeadlineMs    := 0;
  Self._AwsFunctionArn   := '';
  Self._AwsTraceId       := '';
  Self._AwsClientContext := '';
  Self._AwsCognitoId     := '';
end;

procedure TLambdaRuntime.LambdaLoop;
var
  err    : string;  // error message (empty implies no errors)
  req    : string;  // request sent to lambda from the client
  req_ct : string;  // content-type of request
  res    : string;  // response
  res_ct : string;  // content-type of response
begin
  // this is the main lambda processing loop
  while (true) do begin
    Self.ClearHeaders;
    err := GetEvent(req, req_ct);
    if (err = '') then
      err := ProcessEvent(req, req_ct, res, res_ct);
    if (err = '') then
      err := SendResponse(res, res_ct);
    if (err <> '') then begin
      if (Self._AwsRequestId <> '') then begin
        SendError(err);
        writeln('ERROR: ' + err);
      end
      else begin;
        writeln('ERROR: ' + err);
      end;
    end;
  end;
end;

function TLambdaRuntime.GetEvent(out req : string; out req_content_type : string) : string;
var
  Http : TFPHttpClient;
  url : string;
  l : longint;
begin
  // indicate success initially
  Result := '';
  req := '';

  Http := TFPHttpClient.Create(nil);

  try
    // build URL to retrieve the next lambda event
    url := 'http://' + Self._AwsLambdaApi + Self._AwsApiVersion + AWS_URL_LAMBDA_API_NEXT;
    // go out and get the next event
    req := Http.Get(url);
    // parse response headers into our object's fields for easier use later
    // NOTE: VERY IMPORTANT TO TRIM the HEADER VALUES OR ELSE THERE IS AN EXTRA SPACE
    // WHICH WILL SCREW UP THE RESPONSE URL. ONLY TOOK ME 4+ HOURS TO FIGURE THAT ONE OUT!
    Self._AwsRequestId := Trim(Http.ResponseHeaders.Values[ AWS_HDR_LAMBDA_REQUEST_ID ]);
    l := 0;
    TryStrToInt(Trim(Http.ResponseHeaders.Values[ AWS_HDR_LAMBDA_DEADLIN_MS ]), l);
    Self._AwsDeadlineMs := l;
    Self._AwsFunctionArn := Trim(Http.ResponseHeaders.Values[ AWS_HDR_LAMBDA_FUNCTION_ARN ]);
    Self._AwsTraceId := Trim(Http.ResponseHeaders.Values[ AWS_HDR_LAMBDA_TRACE_ID ]);
    Self._AwsClientContext := Trim(Http.ResponseHeaders.Values[ AWS_HDR_LAMBDA_CLIENT_CTX ]);
    Self._AwsCognitoId := Trim(Http.ResponseHeaders.Values[ AWS_HDR_LAMBDA_COGNITO_ID ]);
    req_content_type := Trim(Http.ResponseHeaders.Values[ 'Content-Type' ]);
  finally
    Http.Free;
  end;
end;

function TLambdaRuntime.ProcessEvent(const req : string; const req_content_type : string; out res : string; out res_content_type : string) : string;
begin
  // TO-DO: implement a real processing routine here. For now, it simply echoes the
  // request sent to the function.
  Result := '';
  res_content_type := req_content_type;
  res := req;
end;

function TLambdaRuntime.SendResponse(const res : string; const res_content_type : string ) : string;
var
  Http : TFPHttpClient;
  url : string;
begin
  // indicate success initially
  Result := '';
  Http := TFPHttpClient.Create(nil);
  try
    // build URL to send the response
    url := StringReplace( AWS_URL_LAMBDA_API_RESPONSE, AWS_URL_LAMBDA_REQUEST_ID, Self._AwsRequestId, [] );
    url := 'http://' + Self._AwsLambdaApi + Self._AwsApiVersion + url;
    // POST the response
    Http.AddHeader('Content-Type', res_content_type);
    Http.AddHeader('User-Agent', 'Mozilla/3.0 (compatible; FPC Lambda Fuction)');
    Http.RequestBody := TStringStream.Create(res);
    Http.Post(url);
  finally
    Http.RequestBody.Free;
    Http.Free;
  end;
end;

procedure TLambdaRuntime.SendError(err : string);
var
  Http : TFPHttpClient;
  url : string;
begin
  Http := TFPHttpClient.Create(nil);
  try
    // build URL to send error
    url := StringReplace( AWS_URL_LAMBDA_API_ERROR, AWS_URL_LAMBDA_REQUEST_ID, Self._AwsRequestId, [] );
    url := 'http://' + Self._AwsLambdaApi + Self._AwsApiVersion + url;
    // POST the error
    Http.AddHeader('Content-Type', 'text/plain');
    Http.RequestBody := TStringStream.Create(err);
    Http.Post(url);
  finally
    Http.RequestBody.Free;
    Http.Free;
  end;
end;

procedure TLambdaRuntime.SendInitError(err : string);
var
  Http : TFPHttpClient;
  url : string;
begin
  Http := TFPHttpClient.Create(nil);
  try
    // build URL to send error
    url := 'http://' + Self._AwsLambdaApi + Self._AwsApiVersion + AWS_URL_LAMBDA_API_INIT_ERROR;
    // POST the error
    Http.AddHeader('Content-Type', 'text/plain');
    Http.RequestBody := TStringStream.Create(err);
    Http.Post(url);
  finally
    Http.RequestBody.Free;
    Http.Free;
  end;
end;

constructor TLambdaRuntime.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  StopOnException := False;
end;

destructor TLambdaRuntime.Destroy;
begin
  inherited Destroy;
end;

var
  Application: TLambdaRuntime;
begin
  Application := TLambdaRuntime.Create(nil);
  Application.Title := 'FPC Lambda Runtime';
  Application.Run;
  Application.Free;
end.

