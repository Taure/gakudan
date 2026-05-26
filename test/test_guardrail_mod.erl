-module(test_guardrail_mod).
-moduledoc false.

-behaviour(gakudan_guardrail).

-export([check/3]).

check(output, Text, #{opts := #{block := Bad}}) when is_binary(Text) ->
    case binary:match(Text, Bad) of
        nomatch -> allow;
        _ -> {block, blocked_content}
    end;
check(output, _Text, #{opts := #{replace := New}}) ->
    {transform, New};
check(input, Msgs, #{opts := #{block_input := Bad}}) when is_list(Msgs) ->
    Hit = lists:any(
        fun(#{content := C}) -> is_binary(C) andalso binary:match(C, Bad) =/= nomatch end,
        Msgs
    ),
    case Hit of
        true -> {block, forbidden_input};
        false -> allow
    end;
check(_Stage, _Payload, _Ctx) ->
    allow.
