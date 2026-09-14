use rstest::rstest;

use super::*;

fn decode(bytes: &[u8]) -> Vec<Frame<'static>> {
    let mut options = gif::DecodeOptions::new();
    options.set_color_output(gif::ColorOutput::RGBA);
    let mut decoder = options.read_info(bytes).unwrap();
    let mut frames = Vec::new();
    while let Some(frame) = decoder.read_next_frame().unwrap() {
        frames.push(frame.clone());
    }
    frames
}

// Two red pixels followed by two blue pixels on both rows. YUV values
// are limited-range BT.601 samples; unequal U/V catches plane swaps.
fn colored_frame(format: PixelFormat) -> Vec<u8> {
    let y = [81, 81, 41, 41].repeat(2);
    match format {
        PixelFormat::Rgb => [255, 0, 0, 255, 0, 0, 0, 0, 255, 0, 0, 255].repeat(2),
        PixelFormat::Bgr => [0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 0, 0].repeat(2),
        PixelFormat::Rgba => [255, 0, 0, 0, 255, 0, 0, 127, 0, 0, 255, 255, 0, 0, 255, 0].repeat(2),
        PixelFormat::Bgra => [0, 0, 255, 0, 0, 0, 255, 127, 255, 0, 0, 255, 255, 0, 0, 0].repeat(2),
        PixelFormat::I420 => [y, vec![90, 240], vec![240, 110]].concat(),
        PixelFormat::Yv12 => [y, vec![240, 110], vec![90, 240]].concat(),
        PixelFormat::Ayuv => [
            0, 81, 90, 240, 127, 81, 90, 240, 255, 41, 240, 110, 0, 41, 240, 110,
        ]
        .repeat(2),
        PixelFormat::I422 => [y, [90, 240].repeat(2), [240, 110].repeat(2)].concat(),
        PixelFormat::I444 => [
            y,
            [90, 90, 240, 240].repeat(2),
            [240, 240, 110, 110].repeat(2),
        ]
        .concat(),
        PixelFormat::Nv12 => [y, vec![90, 240, 240, 110]].concat(),
        PixelFormat::Nv21 => [y, vec![240, 90, 110, 240]].concat(),
        PixelFormat::Yuy2 => [81, 90, 81, 240, 41, 240, 41, 110].repeat(2),
        PixelFormat::I42010Le => ten_bit_frame(PixelFormat::I420, false),
        PixelFormat::I42010Be => ten_bit_frame(PixelFormat::I420, true),
        PixelFormat::I42210Le => ten_bit_frame(PixelFormat::I422, false),
        PixelFormat::I42210Be => ten_bit_frame(PixelFormat::I422, true),
        PixelFormat::I44410Le => ten_bit_frame(PixelFormat::I444, false),
        PixelFormat::I44410Be => ten_bit_frame(PixelFormat::I444, true),
    }
}

fn sample_bytes(samples: impl IntoIterator<Item = u16>, big_endian: bool) -> Vec<u8> {
    samples
        .into_iter()
        .flat_map(|sample| {
            if big_endian {
                sample.to_be_bytes()
            } else {
                sample.to_le_bytes()
            }
        })
        .collect()
}

fn ten_bit_frame(format: PixelFormat, big_endian: bool) -> Vec<u8> {
    sample_bytes(
        colored_frame(format)
            .into_iter()
            .map(|sample| u16::from(sample) * 4 + 1),
        big_endian,
    )
}

#[test]
fn rgb_conversion_borrows_the_input_buffer() {
    let pixels = colored_frame(PixelFormat::Rgb);
    let rgb = PixelFormat::Rgb.to_rgb(&pixels, 4, 2).unwrap();
    assert!(matches!(&rgb, std::borrow::Cow::Borrowed(_)));
    assert_eq!(rgb.as_ptr(), pixels.as_ptr());
}

#[rstest]
#[case::rgb(PixelFormat::Rgb)]
#[case::bgr(PixelFormat::Bgr)]
#[case::rgba(PixelFormat::Rgba)]
#[case::bgra(PixelFormat::Bgra)]
#[case::i420(PixelFormat::I420)]
#[case::i422(PixelFormat::I422)]
#[case::i444(PixelFormat::I444)]
#[case::nv12(PixelFormat::Nv12)]
#[case::nv21(PixelFormat::Nv21)]
#[case::yuy2(PixelFormat::Yuy2)]
#[case::yv12(PixelFormat::Yv12)]
#[case::ayuv(PixelFormat::Ayuv)]
#[case::i420_10le(PixelFormat::I42010Le)]
#[case::i420_10be(PixelFormat::I42010Be)]
#[case::i422_10le(PixelFormat::I42210Le)]
#[case::i422_10be(PixelFormat::I42210Be)]
#[case::i444_10le(PixelFormat::I44410Le)]
#[case::i444_10be(PixelFormat::I44410Be)]
fn encodes_expected_colors_and_opaque_alpha(#[case] format: PixelFormat) {
    let mut encoder = Encoder::new(4, 2, format, None);
    let mut bytes = encoder.encode(&colored_frame(format), 10).unwrap();
    assert!(bytes.starts_with(b"GIF89a"));
    let trailer = encoder.finish().unwrap();
    assert_eq!(trailer, [0x3b]);
    bytes.extend(trailer);
    let frames = decode(&bytes);
    assert_eq!(frames.len(), 1);
    assert_eq!(
        (frames[0].width, frames[0].height, frames[0].delay),
        (4, 2, 10)
    );
    for (index, rgba) in frames[0].buffer.chunks_exact(4).enumerate() {
        let expected = if index % 4 < 2 {
            [255_u8, 0, 0, 255]
        } else {
            [0, 0, 255, 255]
        };
        for (actual, expected) in rgba.iter().zip(expected) {
            assert!(
                actual.abs_diff(expected) <= 3,
                "{format:?}, pixel {index}: {rgba:?}"
            );
        }
        assert_eq!(rgba[3], 255);
    }
}

#[test]
fn each_call_emits_its_frame_with_the_supplied_delay() {
    let mut encoder = Encoder::new(4, 2, PixelFormat::Rgb, None);
    let mut bytes = Vec::new();
    for (color, delay) in [([255, 0, 0], 3), ([0, 255, 0], 4), ([0, 0, 255], 3)] {
        let chunk = encoder.encode(&color.repeat(8), delay).unwrap();
        assert!(!chunk.is_empty());
        bytes.extend(chunk);
        let frames = decode(&[bytes.as_slice(), &[0x3b]].concat());
        let frame = frames.last().unwrap();
        assert_eq!(frame.delay, delay);
        for rgba in frame.buffer.chunks_exact(4) {
            assert_eq!(rgba, [color[0], color[1], color[2], 255]);
        }
    }
    assert_eq!(encoder.finish().unwrap(), [0x3b]);
    bytes.push(0x3b);
    assert_eq!(
        decode(&bytes)
            .iter()
            .map(|frame| frame.delay)
            .collect::<Vec<_>>(),
        [3, 4, 3]
    );
}

#[rstest]
#[case::infinite(Some(0), Repeat::Infinite)]
#[case::finite(Some(u16::MAX), Repeat::Finite(u16::MAX))]
#[case::omitted(None, Repeat::Finite(0))]
fn looping_is_infinite_finite_or_omitted(#[case] count: Option<u16>, #[case] expected: Repeat) {
    let mut encoder = Encoder::new(4, 2, PixelFormat::Rgb, count);
    let mut bytes = encoder
        .encode(&colored_frame(PixelFormat::Rgb), 10)
        .unwrap();
    bytes.extend(encoder.finish().unwrap());
    assert_eq!(
        gif::DecodeOptions::new()
            .read_info(bytes.as_slice())
            .unwrap()
            .repeat(),
        expected
    );
    assert_eq!(
        bytes
            .windows(11)
            .filter(|word| *word == b"NETSCAPE2.0")
            .count(),
        usize::from(count.is_some())
    );
}

#[test]
fn minimum_gif_delay_is_written() {
    let mut encoder = Encoder::new(4, 2, PixelFormat::Rgb, None);
    let pixels = colored_frame(PixelFormat::Rgb);
    let mut bytes = encoder.encode(&pixels, 1).unwrap();
    bytes.extend(encoder.finish().unwrap());
    assert_eq!(decode(&bytes)[0].delay, 1);
}

#[test]
fn maximum_gif_delay_is_accepted() {
    let mut encoder = Encoder::new(4, 2, PixelFormat::Rgb, None);
    let mut bytes = encoder
        .encode(&colored_frame(PixelFormat::Rgb), u16::MAX)
        .unwrap();
    bytes.extend(encoder.finish().unwrap());
    assert_eq!(decode(&bytes)[0].delay, u16::MAX);
}

#[rstest]
#[case::rgb(PixelFormat::Rgb)]
#[case::bgr(PixelFormat::Bgr)]
#[case::rgba(PixelFormat::Rgba)]
#[case::bgra(PixelFormat::Bgra)]
#[case::i444(PixelFormat::I444)]
#[case::ayuv(PixelFormat::Ayuv)]
#[case::i444_10le(PixelFormat::I44410Le)]
#[case::i444_10be(PixelFormat::I44410Be)]
fn encodes_odd_dimensions(#[case] format: PixelFormat) {
    let mut encoder = Encoder::new(3, 3, format, None);
    let pixels = match format {
        PixelFormat::I44410Le => sample_bytes([512; 27], false),
        PixelFormat::I44410Be => sample_bytes([512; 27], true),
        _ => vec![128; format.frame_size(3, 3)],
    };
    let mut bytes = encoder.encode(&pixels, 10).unwrap();
    bytes.extend(encoder.finish().unwrap());
    let frames = decode(&bytes);
    assert_eq!((frames[0].width, frames[0].height), (3, 3));
}

#[rstest]
#[case::i420(PixelFormat::I42010Le, PixelFormat::I42010Be, 4)]
#[case::i422(PixelFormat::I42210Le, PixelFormat::I42210Be, 2)]
#[case::i444(PixelFormat::I44410Le, PixelFormat::I44410Be, 1)]
fn endian_variants_produce_identical_pixels(
    #[case] le: PixelFormat,
    #[case] be: PixelFormat,
    #[case] chroma_divisor: usize,
    #[values(4, 64)] width: u16,
) {
    let area = usize::from(width) * 2;
    let samples = [
        vec![325; area],
        vec![361; area / chroma_divisor],
        vec![961; area / chroma_divisor],
    ]
    .concat();
    let little_endian = sample_bytes(samples.iter().copied(), false);
    let big_endian = sample_bytes(samples, true);
    assert_ne!(little_endian, big_endian);
    let rgb = le.to_rgb(&little_endian, width, 2).unwrap();
    assert_eq!(rgb, be.to_rgb(&big_endian, width, 2).unwrap());
    for pixel in rgb.chunks_exact(3) {
        assert!(pixel
            .iter()
            .zip([255_u8, 0, 0])
            .all(|(actual, expected)| actual.abs_diff(expected) <= 3));
    }
}

#[test]
fn ayuv_wide_rows_preserve_colors_and_discard_alpha() {
    let pixels = colored_frame(PixelFormat::Ayuv).repeat(32);
    let mut encoder = Encoder::new(64, 4, PixelFormat::Ayuv, None);
    let mut bytes = encoder.encode(&pixels, 10).unwrap();
    bytes.extend(encoder.finish().unwrap());
    let frames = decode(&bytes);
    for (index, pixel) in frames[0].buffer.chunks_exact(4).enumerate() {
        let expected = if index % 4 < 2 {
            [255_u8, 0, 0, 255]
        } else {
            [0, 0, 255, 255]
        };
        assert!(pixel
            .iter()
            .zip(expected)
            .all(|(actual, expected)| actual.abs_diff(expected) <= 3));
        assert_eq!(pixel[3], 255);
    }
}

#[rstest]
#[case::i420_10le(PixelFormat::I42010Le)]
#[case::i420_10be(PixelFormat::I42010Be)]
#[case::i422_10le(PixelFormat::I42210Le)]
#[case::i422_10be(PixelFormat::I42210Be)]
#[case::i444_10le(PixelFormat::I44410Le)]
#[case::i444_10be(PixelFormat::I44410Be)]
fn ten_bit_frames_accept_unaligned_input(#[case] format: PixelFormat) {
    let pixels = colored_frame(format);
    let mut storage = vec![0; pixels.len() + align_of::<u16>()];
    let offset = usize::from(storage.as_ptr().align_offset(align_of::<u16>()) == 0);
    let input = &mut storage[offset..offset + pixels.len()];
    input.copy_from_slice(&pixels);
    assert_ne!(input.as_ptr().align_offset(align_of::<u16>()), 0);

    let mut encoder = Encoder::new(4, 2, format, None);
    let mut bytes = encoder.encode(input, 10).unwrap();
    bytes.extend(encoder.finish().unwrap());
    let frames = decode(&bytes);
    for (index, pixel) in frames[0].buffer.chunks_exact(4).enumerate() {
        let expected = if index % 4 < 2 {
            [255_u8, 0, 0, 255]
        } else {
            [0, 0, 255, 255]
        };
        assert!(pixel
            .iter()
            .zip(expected)
            .all(|(actual, expected)| actual.abs_diff(expected) <= 3));
    }
}

#[rstest]
#[case::i420_le(PixelFormat::I42010Le, false, 1)]
#[case::i420_be(PixelFormat::I42010Be, true, 1)]
#[case::i422_le(PixelFormat::I42210Le, false, 2)]
#[case::i422_be(PixelFormat::I42210Be, true, 2)]
#[case::i444_le(PixelFormat::I44410Le, false, 4)]
#[case::i444_be(PixelFormat::I44410Be, true, 4)]
fn ten_bit_limited_range_black_and_white(
    #[case] format: PixelFormat,
    #[case] big_endian: bool,
    #[case] chroma_samples: usize,
) {
    let samples = [vec![64, 940, 64, 940], vec![512; chroma_samples * 2]].concat();
    let pixels = sample_bytes(samples, big_endian);
    let mut encoder = Encoder::new(2, 2, format, None);
    let mut bytes = encoder.encode(&pixels, 10).unwrap();
    bytes.extend(encoder.finish().unwrap());
    let frames = decode(&bytes);
    assert_eq!(
        frames[0].buffer.as_ref(),
        [0, 0, 0, 255, 255, 255, 255, 255].repeat(2)
    );
}

#[test]
fn long_stream_emits_every_frame_and_drains_output() {
    let mut encoder = Encoder::new(4, 2, PixelFormat::Rgb, None);
    let pixels = colored_frame(PixelFormat::Rgb);
    for _ in 0..2_000 {
        let bytes = encoder.encode(&pixels, 4).unwrap();
        assert!(!bytes.is_empty());
        assert!(bytes.len() < 1_024);
        assert!(encoder.writer.as_ref().unwrap().get_ref().is_empty());
    }
    assert_eq!(encoder.finish().unwrap(), [0x3b]);
    assert!(encoder.writer.is_none());
}
