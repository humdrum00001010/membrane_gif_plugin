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

fn compose_full_frames(frames: &[Frame<'static>]) -> Vec<Vec<[u8; 4]>> {
    let mut canvas = vec![[0; 4]; frames[0].buffer.len() / 4];
    let mut composed = Vec::new();
    for frame in frames {
        for (pixel, next) in canvas.iter_mut().zip(frame.buffer.as_chunks::<4>().0) {
            if next[3] != 0 {
                *pixel = *next;
            }
        }
        composed.push(canvas.clone());
        if frame.dispose == DisposalMethod::Background {
            // Pillow and FFmpeg clear to transparency only when this frame signals it.
            canvas.fill(if frame.transparent.is_some() {
                [0, 0, 0, 0]
            } else {
                [0, 0, 0, 255]
            });
        }
    }
    composed
}

fn colored_frame(format: PixelFormat) -> Vec<u8> {
    match format {
        PixelFormat::Rgb => [255, 0, 0, 255, 0, 0, 0, 0, 255, 0, 0, 255].repeat(2),
        PixelFormat::Rgba => [255, 0, 0, 255, 0, 0, 255, 255, 0, 255, 0, 0, 0, 255, 0, 0].repeat(2),
    }
}

#[rstest]
#[case::rgb(PixelFormat::Rgb)]
#[case::rgba(PixelFormat::Rgba)]
fn encodes_expected_colors_and_alpha(#[case] format: PixelFormat) {
    let mut encoder = Encoder::new(4, 2, format, None, DisposalMethod::Keep).unwrap();
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
    for (index, rgba) in frames[0].buffer.as_chunks::<4>().0.iter().enumerate() {
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

#[rstest]
#[case::keep(DisposalMethod::Keep)]
#[case::background(DisposalMethod::Background)]
fn opaque_rgba_preserves_all_256_colors(#[case] disposal: DisposalMethod) {
    let pixels: Vec<_> = (0u8..=255)
        .flat_map(|gray| [gray, gray, gray, 255])
        .collect();
    let mut encoder = Encoder::new(16, 16, PixelFormat::Rgba, None, disposal).unwrap();
    let mut bytes = encoder.encode(&pixels, 10).unwrap();
    bytes.extend(encoder.finish().unwrap());

    assert_eq!(decode(&bytes)[0].buffer.as_ref(), pixels.as_slice());
}

#[test]
fn rgba_quantization_preserves_the_binary_alpha_mask() {
    let colors: Vec<_> = (0usize..1_024)
        .map(|index| {
            let alpha = index as u8;
            [
                index as u8,
                (index * 37) as u8,
                ((index / 256) * 64) as u8,
                alpha,
            ]
        })
        .collect();
    let pixels: Vec<_> = colors.iter().flatten().copied().collect();
    let mut encoder = Encoder::new(32, 32, PixelFormat::Rgba, None, DisposalMethod::Keep).unwrap();
    let mut bytes = encoder.encode(&pixels, 10).unwrap();
    bytes.extend(encoder.finish().unwrap());

    let frame = &decode(&bytes)[0];
    for (source, decoded) in colors.iter().zip(frame.buffer.as_chunks::<4>().0) {
        assert_eq!(decoded[3], if source[3] == 0 { 0 } else { 255 });
    }
}

#[rstest]
#[case::keep(DisposalMethod::Keep)]
#[case::background(DisposalMethod::Background)]
fn rgba_alpha_levels_follow_gif_transparency_without_changing_input(
    #[case] disposal: DisposalMethod,
) {
    let pixels: Vec<_> = (0u8..=255).flat_map(|alpha| [0, 0, 255, alpha]).collect();
    let original = pixels.clone();
    let mut encoder = Encoder::new(16, 16, PixelFormat::Rgba, None, disposal).unwrap();
    let mut bytes = encoder.encode(&pixels, 10).unwrap();
    bytes.extend(encoder.finish().unwrap());

    assert_eq!(pixels, original);
    let frame = &decode(&bytes)[0];
    for (pixel, alpha) in frame.buffer.as_chunks::<4>().0.iter().zip(0u8..=255) {
        assert_eq!(*pixel, [0, 0, 255, if alpha == 0 { 0 } else { 255 }]);
    }
}

#[test]
fn background_disposal_clears_each_rgba_frame() {
    let mut encoder =
        Encoder::new(2, 1, PixelFormat::Rgba, None, DisposalMethod::Background).unwrap();
    let colors = [
        [255, 0, 0, 255],
        [0, 255, 0, 0],
        [0, 0, 255, 255],
        [0, 255, 0, 0],
    ];
    let mut bytes = Vec::new();
    for color in colors {
        let pixels = [color, [0, 255, 0, 0]].concat();
        bytes.extend(encoder.encode(&pixels, 10).unwrap());
    }
    bytes.extend(encoder.finish().unwrap());

    let frames = decode(&bytes);
    assert_eq!(
        compose_full_frames(&frames),
        [
            [255, 0, 0, 255],
            [0, 0, 0, 0],
            [0, 0, 255, 255],
            [0, 0, 0, 0],
        ]
        .map(|color| vec![color, [0, 0, 0, 0]])
    );
    assert!(frames.iter().all(|frame| {
        frame.dispose == DisposalMethod::Background && frame.transparent.is_some()
    }));
}

#[test]
fn background_disposal_preserves_255_opaque_colors_and_transparency() {
    let mut encoder =
        Encoder::new(16, 16, PixelFormat::Rgba, None, DisposalMethod::Background).unwrap();
    let mut pixels: Vec<_> = (0u8..255)
        .flat_map(|gray| [gray, gray, gray, 255])
        .collect();
    pixels.extend_from_slice(&[254, 254, 254, 0]);
    let mut bytes = encoder.encode(&pixels, 10).unwrap();
    bytes.extend(encoder.finish().unwrap());

    assert_eq!(decode(&bytes)[0].buffer.as_ref(), pixels.as_slice());
}

#[test]
fn each_call_emits_its_frame_with_the_supplied_delay() {
    let mut encoder = Encoder::new(4, 2, PixelFormat::Rgb, None, DisposalMethod::Keep).unwrap();
    let mut bytes = Vec::new();
    for (color, delay) in [([255, 0, 0], 3), ([0, 255, 0], 4), ([0, 0, 255], 3)] {
        let chunk = encoder.encode(&color.repeat(8), delay).unwrap();
        assert!(!chunk.is_empty());
        bytes.extend(chunk);
        let frames = decode(&[bytes.as_slice(), &[0x3b]].concat());
        let frame = frames.last().unwrap();
        assert_eq!(frame.delay, delay);
        assert_eq!(frame.dispose, DisposalMethod::Keep);
        for rgba in frame.buffer.as_chunks::<4>().0 {
            assert_eq!(*rgba, [color[0], color[1], color[2], 255]);
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
    let mut encoder = Encoder::new(4, 2, PixelFormat::Rgb, count, DisposalMethod::Keep).unwrap();
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
    let mut encoder = Encoder::new(4, 2, PixelFormat::Rgb, None, DisposalMethod::Keep).unwrap();
    let pixels = colored_frame(PixelFormat::Rgb);
    let mut bytes = encoder.encode(&pixels, 1).unwrap();
    bytes.extend(encoder.finish().unwrap());
    assert_eq!(decode(&bytes)[0].delay, 1);
}

#[test]
fn maximum_gif_delay_is_accepted() {
    let mut encoder = Encoder::new(4, 2, PixelFormat::Rgb, None, DisposalMethod::Keep).unwrap();
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
    let mut encoder = Encoder::new(3, 3, format, None, DisposalMethod::Keep).unwrap();
    let pixels = match format {
        PixelFormat::Rgb => [128, 128, 128].repeat(9),
        PixelFormat::Rgba => [128, 128, 128, 255].repeat(9),
    };
    let mut bytes = encoder.encode(&pixels, 10).unwrap();
    bytes.extend(encoder.finish().unwrap());
    let frames = decode(&bytes);
    assert_eq!((frames[0].width, frames[0].height), (3, 3));
}

#[test]
fn long_stream_emits_every_frame_and_drains_output() {
    let mut encoder = Encoder::new(4, 2, PixelFormat::Rgb, None, DisposalMethod::Keep).unwrap();
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
