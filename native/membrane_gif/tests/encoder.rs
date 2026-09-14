use gif::{DisposalMethod, Frame, Repeat};
use rstest::rstest;

use membrane_gif::encoder::Encoder;
use membrane_gif::pixels::PixelFormat;

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

// Two red pixels followed by two blue pixels on both rows. The RGBA frame
// makes the blue pixels transparent and gives the red pixels distinct alpha
// values, exercising the 1-bit transparency mask.
fn colored_frame(format: PixelFormat) -> Vec<u8> {
    match format {
        PixelFormat::Rgb => [255, 0, 0, 255, 0, 0, 0, 0, 255, 0, 0, 255].repeat(2),
        PixelFormat::Rgba => [255, 0, 0, 255, 0, 0, 255, 127, 0, 255, 0, 0, 0, 255, 0, 0].repeat(2),
    }
}

#[rstest]
#[case::rgb(PixelFormat::Rgb)]
#[case::rgba(PixelFormat::Rgba)]
fn encodes_expected_colors_and_alpha(#[case] format: PixelFormat) {
    let mut encoder = Encoder::new(4, 2, format, None).unwrap();
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
        let (rgb, alpha) = match (format, index % 4) {
            (PixelFormat::Rgb, 0..=1) => ([255, 0, 0], 255),
            (PixelFormat::Rgb, _) => ([0, 0, 255], 255),
            (PixelFormat::Rgba, 0) => ([255, 0, 0], 255),
            (PixelFormat::Rgba, 1) => ([0, 0, 255], 255),
            (PixelFormat::Rgba, _) => ([0, 255, 0], 0),
        };
        for (actual, expected) in rgba.iter().copied().zip(rgb) {
            assert!(
                actual.abs_diff(expected) <= 3,
                "{format:?}, pixel {index}: {rgba:?}"
            );
        }
        assert_eq!(rgba[3], alpha, "{format:?}, pixel {index}: {rgba:?}");
    }
}

#[test]
fn rgba_frames_reserve_transparency_for_independent_frames() {
    let mut encoder = Encoder::new(2, 1, PixelFormat::Rgba, None).unwrap();
    let mut bytes = Vec::new();

    for pixels in [
        [255, 0, 0, 255, 255, 0, 0, 255],
        [0, 0, 0, 0, 0, 0, 255, 255],
        [0, 255, 0, 255, 0, 255, 0, 255],
        [0, 0, 0, 0, 0, 0, 255, 255],
    ] {
        bytes.extend(encoder.encode(&pixels, 10).unwrap());
    }
    bytes.extend(encoder.finish().unwrap());

    let mut options = gif::DecodeOptions::new();
    options.set_color_output(gif::ColorOutput::Indexed);
    let mut decoder = options.read_info(bytes.as_slice()).unwrap();

    for expected_transparent_pixels in [0, 1, 0, 1] {
        let frame = decoder.read_next_frame().unwrap().unwrap();
        assert_eq!(frame.dispose, DisposalMethod::Background);
        let transparent = frame
            .transparent
            .expect("RGBA frame must reserve transparency");
        assert_eq!(
            frame
                .buffer
                .iter()
                .filter(|&&index| index == transparent)
                .count(),
            expected_transparent_pixels
        );
    }
}

#[test]
fn opaque_rgba_full_palette_does_not_gain_transparent_pixels() {
    let mut encoder = Encoder::new(16, 16, PixelFormat::Rgba, None).unwrap();
    let pixels: Vec<_> = (0..=255).flat_map(|red| [red, 0, 0, 255]).collect();
    let mut bytes = encoder.encode(&pixels, 10).unwrap();
    bytes.extend(encoder.finish().unwrap());

    let mut options = gif::DecodeOptions::new();
    options.set_color_output(gif::ColorOutput::Indexed);
    let mut decoder = options.read_info(bytes.as_slice()).unwrap();
    let frame = decoder.read_next_frame().unwrap().unwrap();
    let transparent = frame
        .transparent
        .expect("RGBA frame must reserve transparency");
    assert!(frame.buffer.iter().all(|&index| index != transparent));
}

#[test]
fn each_call_emits_its_frame_with_the_supplied_delay() {
    let mut encoder = Encoder::new(4, 2, PixelFormat::Rgb, None).unwrap();
    let mut bytes = Vec::new();
    for (color, delay) in [([255, 0, 0], 3), ([0, 255, 0], 4), ([0, 0, 255], 3)] {
        let chunk = encoder.encode(&color.repeat(8), delay).unwrap();
        assert!(!chunk.is_empty());
        bytes.extend(chunk);
        let frames = decode(&[bytes.as_slice(), &[0x3b]].concat());
        let frame = frames.last().unwrap();
        assert_eq!(frame.delay, delay);
        assert_eq!(frame.dispose, DisposalMethod::Keep);
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
#[case::finite(Some(65_535), Repeat::Finite(u16::MAX))]
#[case::omitted(None, Repeat::Finite(0))]
fn looping_is_infinite_finite_or_omitted(#[case] count: Option<u64>, #[case] expected: Repeat) {
    let mut encoder = Encoder::new(4, 2, PixelFormat::Rgb, count).unwrap();
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
    let mut encoder = Encoder::new(4, 2, PixelFormat::Rgb, None).unwrap();
    let pixels = colored_frame(PixelFormat::Rgb);
    let mut bytes = encoder.encode(&pixels, 1).unwrap();
    bytes.extend(encoder.finish().unwrap());
    assert_eq!(decode(&bytes)[0].delay, 1);
}

#[test]
fn maximum_gif_delay_is_accepted() {
    let mut encoder = Encoder::new(4, 2, PixelFormat::Rgb, None).unwrap();
    let mut bytes = encoder
        .encode(&colored_frame(PixelFormat::Rgb), u16::MAX)
        .unwrap();
    bytes.extend(encoder.finish().unwrap());
    assert_eq!(decode(&bytes)[0].delay, u16::MAX);
}

#[rstest]
#[case::rgb(PixelFormat::Rgb)]
#[case::rgba(PixelFormat::Rgba)]
fn encodes_odd_dimensions(#[case] format: PixelFormat) {
    let mut encoder = Encoder::new(3, 3, format, None).unwrap();
    let pixels = vec![128; format.frame_size(3, 3)];
    let mut bytes = encoder.encode(&pixels, 10).unwrap();
    bytes.extend(encoder.finish().unwrap());
    let frames = decode(&bytes);
    assert_eq!((frames[0].width, frames[0].height), (3, 3));
}

#[test]
fn long_stream_emits_every_frame_and_drains_output() {
    let mut encoder = Encoder::new(4, 2, PixelFormat::Rgb, None).unwrap();
    let pixels = colored_frame(PixelFormat::Rgb);
    let mut bytes = Vec::new();
    for _ in 0..2_000 {
        let chunk = encoder.encode(&pixels, 4).unwrap();
        assert!(!chunk.is_empty());
        assert!(chunk.len() < 1_024);
        bytes.extend(chunk);
    }
    bytes.extend(encoder.finish().unwrap());
    assert_eq!(decode(&bytes).len(), 2_000);
}
