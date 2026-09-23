# Vendored SpeexDSP (echo cancellation)

Source: https://github.com/xiph/speexdsp (BSD licence, see `COPYING`).
Tag: `SpeexDSP-1.2.1`, commit `1b28a0f61bc31162979e1f26f3981fc3637095c8`.

Minimal file set needed for the MDF acoustic echo canceller (`mdf.c`) plus
the preprocessor's residual-echo suppression (`preprocess.c`), copied
unmodified from `libspeexdsp/` and `include/speex/`:

- `mdf.c` — the echo canceller itself (AUMDF algorithm).
- `preprocess.c`, `filterbank.c`/`.h` — residual echo/noise suppression,
  driven via `SPEEX_PREPROCESS_SET_ECHO_STATE`.
- `fftwrap.c`/`.h`, `kiss_fft.c`/`.h`, `kiss_fftr.c`/`.h`,
  `_kiss_fft_guts.h` — FFT backend (`USE_KISS_FFT`, set as a
  `GCC_PREPROCESSOR_DEFINITIONS` build setting on the VoiceInk target,
  alongside `FLOATING_POINT` - the autotools build normally supplies both
  via `config.h`/`configure`, which this manual build skips - and
  `EXPORT=` - normally a visibility attribute from the same generated
  `config.h`, empty here since none of this is built as a shared library).
- `arch.h`, `os_support.h`, `math_approx.h`, `pseudofloat.h`,
  `fixed_generic.h` — internal support headers pulled in by the above.
- `include/speex/speex_echo.h`, `speex_preprocess.h`,
  `speexdsp_types.h` — public API, imported into Swift via
  `VoiceInk-Bridging-Header.h`.

Not vendored: fixed-point (`FIXED_POINT`) code paths, alternate FFT
backends (smallft/MKL/IPP/FFTW3), the resampler, jitter buffer, and test
programs — none of it is reachable from `mdf.c`/`preprocess.c` on this
build configuration (floating point, `USE_KISS_FFT`).

To refresh: re-clone the tag above and re-copy the same file list; no
patches have been applied to any vendored file.
