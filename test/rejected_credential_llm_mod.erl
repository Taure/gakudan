-module(rejected_credential_llm_mod).
-moduledoc false.
-behaviour(gakudan_llm).

-export([complete/2]).

complete(_Req, _Opts) ->
    {error, {http_error, 401, ~"invalid x-api-key"}}.
