#include <erl_nif.h>
#include <libavutil/mem.h>
#include <stdint.h>

// Configure FFmpeg's actual allocator; no encoder or allocation calls replaced.
static ERL_NIF_TERM set(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  ErlNifUInt64 limit;
  if (!enif_get_uint64(env, argv[0], &limit) || limit > SIZE_MAX)
    return enif_make_badarg(env);
  av_max_alloc((size_t)limit);
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM reset(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  av_max_alloc(SIZE_MAX);
  return enif_make_atom(env, "ok");
}

static ErlNifFunc functions[] = {{"set", 1, set, 0}, {"reset", 0, reset, 0}};
ERL_NIF_INIT(Elixir.Membrane.GIF.Test.AllocationLimit.Nif, functions, NULL, NULL, NULL, NULL)
