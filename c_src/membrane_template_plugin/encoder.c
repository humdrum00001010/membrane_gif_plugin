#include "encoder.h"

#include <stdint.h>

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wall"
#pragma GCC diagnostic ignored "-Wextra"
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>
#pragma GCC diagnostic pop

struct GIFEncoder {
  AVCodecContext *codec_ctx;
  struct SwsContext *sws_ctx;
  AVFrame *frame; // rgb8 frame handed to the encoder
  enum AVPixelFormat src_pix_fmt;
  int width;
  int height;
  int64_t next_pts;
};

#define ENCODER_ENCODE_ERROR -2

static void destroy_encoder(GIFEncoder *encoder) {
  if (!encoder) {
    return;
  }
  av_frame_free(&encoder->frame);
  sws_freeContext(encoder->sws_ctx);
  avcodec_free_context(&encoder->codec_ctx);
  av_free(encoder);
}

void handle_destroy_state(UnifexEnv *env, State *state) {
  UNIFEX_UNUSED(env);
  destroy_encoder(state->encoder);
}

static inline enum AVPixelFormat pix_fmt_to_ffmpeg(PixelFormat format) {
  switch (format) {
  case PIXEL_FORMAT_I420:
    return AV_PIX_FMT_YUV420P;
  case PIXEL_FORMAT_I422:
    return AV_PIX_FMT_YUV422P;
  case PIXEL_FORMAT_I444:
    return AV_PIX_FMT_YUV444P;
  case PIXEL_FORMAT_RGB:
    return AV_PIX_FMT_RGB24;
  case PIXEL_FORMAT_BGR:
    return AV_PIX_FMT_BGR24;
  case PIXEL_FORMAT_RGBA:
    return AV_PIX_FMT_RGBA;
  case PIXEL_FORMAT_BGRA:
    return AV_PIX_FMT_BGRA;
  case PIXEL_FORMAT_NV12:
    return AV_PIX_FMT_NV12;
  case PIXEL_FORMAT_NV21:
    return AV_PIX_FMT_NV21;
  case PIXEL_FORMAT_YUY2:
    return AV_PIX_FMT_YUYV422;
  default:
    return AV_PIX_FMT_NONE;
  }
}

// Returns an error reason, or NULL on success. The resource destructor releases
// any partially initialized fields if initialization fails.
static const char *initialize_encoder(GIFEncoder **out_encoder, int width, int height,
                                      PixelFormat pix_fmt) {
  GIFEncoder *encoder = av_mallocz(sizeof(*encoder));
  *out_encoder = encoder;
  if (!encoder) {
    return "encoder_alloc";
  }
  encoder->width = width;
  encoder->height = height;
  encoder->src_pix_fmt = pix_fmt_to_ffmpeg(pix_fmt);

  const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_GIF);
  encoder->codec_ctx = avcodec_alloc_context3(codec);
  if (!encoder->codec_ctx) {
    return "codec_alloc";
  }
  encoder->codec_ctx->width = width;
  encoder->codec_ctx->height = height;
  // The only formats the gif encoder accepts are palettized/8-bit ones; rgb8
  // (3-3-2 bits) is the one libswscale can produce without a palette step.
  encoder->codec_ctx->pix_fmt = AV_PIX_FMT_RGB8;
  // Synthetic PTS use centiseconds. FFmpeg writes a default GCE
  // delay of 5; Membrane.GIF.Muxing sets playback delays from input PTS.
  encoder->codec_ctx->time_base = (AVRational){1, 100};
  if (avcodec_open2(encoder->codec_ctx, codec, NULL) < 0) {
    return "codec_open";
  }
  encoder->sws_ctx =
      sws_getContext(width, height, encoder->src_pix_fmt, width, height,
                     AV_PIX_FMT_RGB8, SWS_BILINEAR, NULL, NULL, NULL);
  encoder->frame = av_frame_alloc();
  encoder->frame->format = AV_PIX_FMT_RGB8;
  encoder->frame->width = width;
  encoder->frame->height = height;
  if (av_frame_get_buffer(encoder->frame, 0) < 0) {
    return "frame_buffer";
  }

  return NULL;
}

UNIFEX_TERM create(UnifexEnv *env, int width, int height, PixelFormat pix_fmt) {
  State *state = unifex_alloc_state(env);
  const char *error = initialize_encoder(&state->encoder, width, height, pix_fmt);
  UNIFEX_TERM res = error ? create_result_error(env, error)
                         : create_result_ok(env, state);
  unifex_release_state(env, state);
  return res;
}

// Drains every packet the encoder has ready into freshly allocated payloads.
static int receive_packets(UnifexEnv *env, GIFEncoder *encoder,
                           UnifexPayload ***out_packets,
                           unsigned int *out_count) {
  size_t capacity = 4;
  unsigned int count = 0;
  UnifexPayload **packets = unifex_alloc(capacity * sizeof(*packets));
  AVPacket *pkt = av_packet_alloc();
  int ret = 0;

  if (!pkt) {
    ret = ENCODER_ENCODE_ERROR;
    goto finish;
  }

  while (1) {
    ret = avcodec_receive_packet(encoder->codec_ctx, pkt);
    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
      ret = 0;
      break;
    } else if (ret < 0) {
      ret = ENCODER_ENCODE_ERROR;
      break;
    }

    if (count >= capacity) {
      capacity *= 2;
      packets = unifex_realloc(packets, capacity * sizeof(*packets));
    }

    packets[count] = unifex_alloc(sizeof(UnifexPayload));
    unifex_payload_alloc(env, UNIFEX_PAYLOAD_BINARY, pkt->size, packets[count]);
    memcpy(packets[count]->data, pkt->data, pkt->size);
    count++;
    av_packet_unref(pkt);
  }

finish:
  av_packet_free(&pkt);
  *out_packets = packets;
  *out_count = count;
  return ret;
}

static void free_packets(UnifexPayload **packets, unsigned int count) {
  for (unsigned int i = 0; i < count; i++) {
    unifex_payload_release(packets[i]);
    unifex_free(packets[i]);
  }
  unifex_free(packets);
}

UNIFEX_TERM encode(UnifexEnv *env, UnifexPayload *payload, State *state) {
  GIFEncoder *encoder = state->encoder;
  UNIFEX_TERM res;
  UnifexPayload **packets = NULL;
  unsigned int count = 0;

  int required_size = av_image_get_buffer_size(
      encoder->src_pix_fmt, encoder->width, encoder->height, 1);
  if (required_size < 0 || payload->size != (unsigned int)required_size) {
    return encode_result_error(env, "invalid_frame_size");
  }

  const uint8_t *src_data[4];
  int src_linesize[4];
  av_image_fill_arrays((uint8_t **)src_data, src_linesize, payload->data,
                       encoder->src_pix_fmt, encoder->width, encoder->height, 1);

  if (av_frame_make_writable(encoder->frame) < 0) {
    return encode_result_error(env, "frame_writable");
  }

  sws_scale(encoder->sws_ctx, src_data, src_linesize, 0, encoder->height,
            encoder->frame->data, encoder->frame->linesize);

  encoder->frame->pts = encoder->next_pts++;

  if (avcodec_send_frame(encoder->codec_ctx, encoder->frame) < 0) {
    return encode_result_error(env, "send_frame");
  }

  res = receive_packets(env, encoder, &packets, &count) >= 0 ?
    encode_result_ok(env, packets, count) :
    encode_result_error(env, "encode");

  free_packets(packets, count);
  return res;
}

UNIFEX_TERM flush(UnifexEnv *env, State *state) {
  GIFEncoder *encoder = state->encoder;
  UNIFEX_TERM res;
  UnifexPayload **packets = NULL;
  unsigned int count = 0;

  if (avcodec_send_frame(encoder->codec_ctx, NULL) < 0) {
    return flush_result_error(env, "send_frame");
  }

  res = receive_packets(env, encoder, &packets, &count) >= 0 ?
    flush_result_ok(env, packets, count) :
    flush_result_error(env, "encode");

  free_packets(packets, count);
  return res;
}
