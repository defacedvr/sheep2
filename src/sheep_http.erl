-module(sheep_http).


-behaviour(cowboy_sub_protocol).

-export([upgrade/4]).

-export([
    get_header/2,
    get_header/3,
    error_handler/2,
    error_handler/3,
    request/1,
    response/1
]).

-include("sheep.hrl").

-spec upgrade(cowboy_req:req(), cowboy_middleware:env(), module(), any()) ->
                     {ok, cowboy_req:req(), cowboy_middleware:env()}.
upgrade(CowReq, Env, Handler, HandlerOpts) ->
    {Method, _} = cowboy_req:method(CowReq),
    {Bindings, _} = cowboy_req:bindings(CowReq),
    {Query, _} = cowboy_req:qs_vals(CowReq),
    {Headers, _} = cowboy_req:headers(CowReq),

    Request = request(#{
        method => Method,
        headers => Headers,
        bindings => to_map(Bindings),
        'query' => to_map(Query)
    }),

    {SheepOpts, Response} = try
        {Opts, State} = case
            erlang:function_exported(Handler, sheep_init, 2)
        of
            true ->
                Handler:sheep_init(Request, HandlerOpts);
            false -> {[], []}
        end,
        UpdRequest = decode_payload(CowReq, Request, Opts),
        {Opts, handle(UpdRequest, Handler, HandlerOpts, Opts, State)}
    catch
        throw:{sheep, #{status_code := StatusCode} = ErrorResponse} ->
            {[], handle_error(
              Handler, [Request, StatusCode, ErrorResponse])};
        Class:Reason ->
            {[], handle_exception(Handler, [Request, {Class, Reason}])}
    end,

    #{status_code := ResponseCode, headers := ResponseHeaders, body := Body} =
        encode_payload(CowReq, Response, SheepOpts),

    {ok, CowResponse} = cowboy_req:reply(ResponseCode, ResponseHeaders, Body, CowReq),
    sheep_logging:request(CowResponse, ResponseCode),
    {ok, CowResponse, Env}.


call_handlers(_Request, _Module, [], _State) ->
    throw({sheep, sheep_response:new_204()});


call_handlers(Request, Module, [HandlerFun|Handlers], State) ->
    Fun = case
        erlang:is_function(HandlerFun, 2)
    of
        true -> HandlerFun;
        _ ->
            case
                erlang:function_exported(Module, HandlerFun, 2)
            of
                true -> fun Module:HandlerFun/2;
                _ -> throw({sheep, sheep_response:new_501()})
            end
    end,
    case Fun(Request, State) of
        {noreply, NewState} ->
            call_handlers(Request, Module, Handlers, NewState);
        {noreply, NewRequest, NewState} ->
            call_handlers(NewRequest, Module, Handlers, NewState);
        Result ->
            Result
    end.


-spec handle(sheep_request(), module(), list(), list(), any()) -> sheep_response().
handle(#{method := Method} = Request, HandlerModule, _HandlerOpts, SheepOpts, State) ->
    MethodsSpec = proplists:get_value(methods_spec, SheepOpts, ?PROTOCOL_METHODS_SPEC),
    FindHandlers = lists:keyfind(Method, 1, MethodsSpec),

    Result = case FindHandlers of
        false ->
            throw({sheep, sheep_response:new_405()});
        {_, Handlers} when is_list(Handlers) ->
            call_handlers(Request, HandlerModule, Handlers, State)
    end,
    case Result of
        {ok, OkResponse} -> OkResponse;
        {error, ErrorResponse} ->
            case ErrorResponse of
                #{status_code := StatusCode}
                when is_integer(StatusCode) ->
                    handle_error(
                        HandlerModule,
                        [Request, StatusCode, ErrorResponse]);
                _ ->
                    handle_error(
                        HandlerModule,
                        [Request, ErrorResponse])
            end;
        InvalidResponse ->
            handle_error(
                HandlerModule,
                [Request, {invalid, InvalidResponse}])
    end.


handle_error(Handler, Args) ->
    handle_error(Handler, error_handler, Args).

handle_exception(Handler, Args) ->
    handle_error(Handler, exception_handler, Args).

handle_error(Handler, Fn, Args) ->
    case
        erlang:function_exported(Handler, Fn, length(Args))
    of
        true ->
            try
                apply(Handler, Fn, Args)
            catch
                Class:Reason ->
                    error_logger:error_report([
                        {error, invalid_handler},
                        {handler, Handler},
                        {exception, {Class, Reason}},
                        {stacktrace, erlang:get_stacktrace()}
                    ]),
                    apply(?MODULE, Fn, Args)
            end;
        false ->
            apply(?MODULE, Fn, Args)
    end.


-spec error_handler(sheep_request(), integer(), map()) -> sheep_response().
error_handler(_Request, _StatusCode, Response) ->
    Response.

error_handler(_Request, Error) ->
    error_logger:error_report([
        {error, Error},
        {stacktrace, erlang:get_stacktrace()}
    ]),
    sheep_response:new_500().


-spec error_handler(sheep_request(), {atom(), any()}) -> sheep_response().
exception_handler(_Request, Exception) ->
    error_logger:error_report([
        {exception, Exception},
        {stacktrace, erlang:get_stacktrace()}
    ]),
    sheep_response:new_500().


-spec decode_payload(cowboy_req:req(), sheep_request(), list()) -> sheep_request().
decode_payload(CowReq, Request, SheepOpts) ->
    {RawContentType, _} = cowboy_req:header(<<"content-type">>, CowReq, ?CT_APP_JSON),

    % http://www.w3.org/Protocols/rfc1341/4_Content-Type.html
    CleanContentType = case
        binary:split(RawContentType, <<";">>)
    of
        [ContentType, _Parameters] -> ContentType;
        [ContentType] -> ContentType
    end,

    DecodeSpec = proplists:get_value(decode_spec, SheepOpts, ?PROTOCOL_DECODE_SPEC),

    Fn = case proplists:get_value(CleanContentType, DecodeSpec) of
        undefined ->
            error_logger:info_report([
                {error, "not supported"},
                {<<"content-type">>, RawContentType}
            ]),
            throw({
                sheep, sheep_response:new(415, <<"Not supported 'content-type'">>)});
        F -> F
    end,

    case cowboy_req:has_body(CowReq) of
        true ->
            {ok, Body, _} = cowboy_req:body(CowReq),
            try
                Request#{body := Fn(Body)}
            catch
                Class:Reason ->
                    error_logger:info_report([
                        {payload, Body},
                        {description, "can't decode payload"},
                        {exception, {Class,Reason}},
                        {stacktrace, erlang:get_stacktrace()}
                    ]),
                    throw({sheep,
                        sheep_response:new(
                            400,
                            <<"Can't decode '", RawContentType/binary, "' payload">>)})
            end;
        false -> Request
    end.


-spec encode_payload(cowboy_req:req(), sheep_request(), list()) -> sheep_request().
encode_payload(CowReq, #{body := Data, headers := Headers} = Response, SheepOpts) ->
    {AcceptContentType, _} = cowboy_req:header(<<"accept">>, CowReq, ?CT_APP_JSON),
    EncodeSpec = proplists:get_value(encode_spec, SheepOpts, ?PROTOCOL_ENCODE_SPEC),

    case proplists:get_value(AcceptContentType, EncodeSpec) of
        undefined ->
            % TODO: check should be before performing request
            sheep_response:new(406, <<"Not acceptable">>);
        Fn ->
            try
                Response#{
                  headers := lists:keystore(
                               <<"content-type">>, 1, Headers,
                               {<<"content-type">>, AcceptContentType}),
                  body := Fn(Data)}
            catch
                Class:Reason ->
                    error_logger:info_report([
                        {error, encode_payload},
                        {payload, Data},
                        {description, "can't encode payload"},
                        {exception, {Class,Reason}},
                        {stacktrace, erlang:get_stacktrace()}
                    ]),
                    sheep_response:new(
                        500, <<"Can't encode '", AcceptContentType/binary, "' payload">>)
            end
    end.


-spec get_header(binary(), sheep_request()) -> binary().
get_header(Name, Request) ->
    get_header(Name, Request, undefined).

-spec get_header(binary(), sheep_request(), any()) -> binary().
get_header(Name, #{headers := Headers}, Default) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, Value} -> Value;
        false -> Default
    end.


-spec to_map([proplists:property()]) -> map().
to_map(List) ->
    maps:from_list(
      lists:map(fun({K, V}) when is_atom(K) ->
                        {list_to_binary(atom_to_list(K)), V};
                   ({K, V}) when is_list(K) ->
                        {list_to_binary(K), V};
                   ({K, V}) when is_binary(K) ->
                        {K, V}
                end, List)).


-spec request(map()) -> sheep_request().
request(Data) ->
    maps:merge(#{
                  meta => [],
                  method => undefined,
                  headers => [],
                  bindings => {[]},
                  query => {[]},
                  body => #{}
                }, Data).


-spec response(map()) -> sheep_response().
response(Data) ->
    maps:merge(#{
                  status_code => 204,
                  headers => [],
                  body => #{}
                }, Data).
