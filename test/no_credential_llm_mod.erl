-module(no_credential_llm_mod).
-moduledoc false.
-behaviour(gakudan_llm).

-export([complete/2]).

complete(_Req, _Opts) ->
    {error, no_api_key}.
