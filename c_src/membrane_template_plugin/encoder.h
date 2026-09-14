#pragma once

typedef struct GIFEncoder GIFEncoder;
typedef struct State State;

struct State {
  GIFEncoder *encoder;
};

#include "_generated/encoder.h"
