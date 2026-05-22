-module(gakudan_agent).
-moduledoc """
Behaviour for an agent role.

Implement this in your own module and pass the module name in `start_run/1`'s
`agents` list. The minimal contract is: identify yourself, declare a system
prompt, declare tools and a model. The library wires the rest.
""".

-export_type([id/0, tool_spec/0, model/0]).

-type id() :: atom().
-type tool_spec() :: module().
-type model() :: binary().

-callback id() -> id().
-callback system_prompt() -> binary().
-callback tools() -> [tool_spec()].
-callback model() -> model().

-optional_callbacks([]).
