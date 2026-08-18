-module(gakudan_test_repo).
-moduledoc false.
-behaviour(kura_repo).

-export([otp_app/0, start/0]).
-export([
    all/1,
    get/2,
    get_by/2,
    one/1,
    insert/1, insert/2,
    update/1,
    delete/1,
    update_all/2,
    delete_all/1,
    insert_all/2, insert_all/3,
    exists/1,
    reload/2,
    transaction/1,
    multi/1,
    preload/3,
    query/2
]).

otp_app() -> gakudan.

start() ->
    application:set_env(kura, dialect, kura_dialect_pg),
    application:set_env(gakudan, gakudan_test_repo, #{
        pool => gakudan_test_repo,
        backend => kura_backend_postgres,
        pool_module => kura_pool_minato,
        driver_module => kura_driver_minato,
        database => env(~"GAKUDAN_TEST_DB", ~"gakudan_test"),
        hostname => env(~"GAKUDAN_TEST_DB_HOST", ~"localhost"),
        port => env_int(~"GAKUDAN_TEST_DB_PORT", 5555),
        username => env(~"GAKUDAN_TEST_DB_USER", ~"postgres"),
        password => env(~"GAKUDAN_TEST_DB_PASSWORD", ~"root"),
        pool_size => 5
    }),
    kura_repo_worker:start(?MODULE).

env(Name, Default) ->
    case os:getenv(binary_to_list(Name)) of
        false -> Default;
        "" -> Default;
        V -> list_to_binary(V)
    end.

env_int(Name, Default) ->
    case os:getenv(binary_to_list(Name)) of
        false -> Default;
        "" -> Default;
        V -> list_to_integer(V)
    end.

all(Q) -> kura_repo_worker:all(?MODULE, Q).
get(Schema, Id) -> kura_repo_worker:get(?MODULE, Schema, Id).
get_by(Schema, Clauses) -> kura_repo_worker:get_by(?MODULE, Schema, Clauses).
one(Q) -> kura_repo_worker:one(?MODULE, Q).
insert(CS) -> kura_repo_worker:insert(?MODULE, CS).
insert(CS, Opts) -> kura_repo_worker:insert(?MODULE, CS, Opts).
update(CS) -> kura_repo_worker:update(?MODULE, CS).
delete(CS) -> kura_repo_worker:delete(?MODULE, CS).
update_all(Query, Updates) -> kura_repo_worker:update_all(?MODULE, Query, Updates).
delete_all(Query) -> kura_repo_worker:delete_all(?MODULE, Query).
insert_all(Schema, Entries) -> kura_repo_worker:insert_all(?MODULE, Schema, Entries).
insert_all(Schema, Entries, Opts) -> kura_repo_worker:insert_all(?MODULE, Schema, Entries, Opts).
exists(Q) -> kura_repo_worker:exists(?MODULE, Q).
reload(Schema, Record) -> kura_repo_worker:reload(?MODULE, Schema, Record).
transaction(Fun) -> kura_repo_worker:transaction(?MODULE, Fun).
multi(Multi) -> kura_repo_worker:multi(?MODULE, Multi).
preload(Schema, Records, Assocs) -> kura_repo_worker:preload(?MODULE, Schema, Records, Assocs).
query(SQL, Params) -> kura_repo_worker:query(?MODULE, SQL, Params).
