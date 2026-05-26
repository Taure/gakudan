# 11. Cloud-provider Claude backends (Vertex, Bedrock)

Date: 2026-05-26

## Status

Accepted (v0.5). `gakudan_llm_vertex` implemented; a Bedrock backend can
follow the same pattern.

## Context

Enterprises that cannot quickly sign a direct Anthropic API contract very
often already have a GCP or AWS agreement with procurement done. Claude
runs on GCP Vertex AI and AWS Bedrock under those contracts, so targeting
them is the **sanctioned enterprise-access path** - unlike piggybacking a
Claude subscription's OAuth credentials, which is against Anthropic's
terms.

This deliberately relaxes the earlier "keep LLM backends minimal
(anthropic + stub)" stance - first Gemini, now Vertex. The relaxation is
justified: cloud-hosted Claude speaks the same Messages API, so the
marginal cost per backend is small (see reuse below), and it unlocks
regulated / enterprise adoption that the direct API gates.

## Decision

- **Cloud Claude backends are thin adapters over `gakudan_llm_anthropic`.**
  That module exports the format helpers (`build_body/2`,
  `parse_response/1`, `fresh_stream_acc/0`, `feed_stream_chunk/4`,
  `finalise/1`). A cloud backend reuses them and supplies only the
  endpoint, the auth header, and the small request-body delta.
- **`gakudan_llm_vertex`** POSTs the Anthropic body - minus `model`, plus
  `anthropic_version: vertex-2023-10-16` - to the Vertex
  `:rawPredict` / `:streamRawPredict` endpoint for
  `publishers/anthropic/models/{model}`, with a Google bearer token.
- **Auth is the host's job.** The backend takes `access_token` or a
  `token_fun` (a `fun/0` returning a fresh token - the recommended,
  refresh-capable path) in opts, or reads `GOOGLE_VERTEX_TOKEN`. gakudan
  does **not** bundle a Google ADC / OAuth implementation; that would
  drag heavy deps into a small library. The host wires up ADC and hands
  gakudan a token.
- **Config:** `{gakudan_llm_vertex, #{project => P, location => L,
  token_fun => F}}`; the model id comes from the agent's `model/0`.

## Consequences

**Positive.**

- Enterprise / regulated access to Claude without a direct Anthropic
  contract, riding an existing GCP relationship (EU data residency, etc.).
- Near-zero duplication: the request/response/SSE machinery is the
  already-tested Anthropic code. A Bedrock backend follows the identical
  shape, swapping the bearer token for SigV4 signing.

**Negative.**

- The backend count grows (deliberate, per above).
- The host must supply and refresh the Google token; a stale static
  `access_token` will start returning 401s after ~1h, which is why
  `token_fun` is the documented path.
- The live HTTP path is untestable without GCP credentials, so tests
  cover the pure adapter logic (endpoint URL, body delta, auth/config
  resolution) and lean on the shared, already-tested Anthropic parsing.
