#pragma once

#include <stdint.h>

#ifndef NPC_XLEN
#error "NPC_XLEN must be supplied by the selected NPC_CONFIG"
#endif

#if NPC_XLEN == 32
using npc_word_t = uint32_t;
#elif NPC_XLEN == 64
using npc_word_t = uint64_t;
#else
#error "NPC_XLEN must be either 32 or 64"
#endif

static constexpr int NPC_WORD_HEX_DIGITS = NPC_XLEN / 4;

