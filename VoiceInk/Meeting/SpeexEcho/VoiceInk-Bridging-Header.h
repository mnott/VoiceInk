#ifndef VoiceInk_Bridging_Header_h
#define VoiceInk_Bridging_Header_h

// Relative to this header's own location (not via HEADER_SEARCH_PATHS) so that targets which
// merely `@testable import VoiceInk` - and re-scan this bridging header as part of validating
// the VoiceInk module they're importing, without themselves declaring the SpeexEcho include
// path - can still resolve it.
#include "include/speex/speex_echo.h"
#include "include/speex/speex_preprocess.h"

#endif
