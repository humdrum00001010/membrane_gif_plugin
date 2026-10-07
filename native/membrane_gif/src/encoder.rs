use std::num::TryFromIntError;

use gif::{DisposalMethod, EncodingError, Repeat};

use crate::pixels::PixelFormat;

pub struct Encoder {
    width: u16,
    height: u16,
    format: PixelFormat,
    loop_count: Option<u16>,
    disposal: DisposalMethod,
    writer: Option<gif::Encoder<Vec<u8>>>,
}

impl Encoder {
    pub fn new(
        width: u64,
        height: u64,
        format: PixelFormat,
        loop_count: Option<u64>,
        disposal: DisposalMethod,
    ) -> Result<Self, TryFromIntError> {
        let width = u16::try_from(width)?;
        let height = u16::try_from(height)?;
        let loop_count = loop_count.map(u16::try_from).transpose()?;
        Ok(Self {
            width,
            height,
            format,
            loop_count,
            disposal,
            writer: None,
        })
    }

    pub fn encode(&mut self, pixels: &[u8], delay_cs: u16) -> Result<Vec<u8>, EncodingError> {
        let mut frame = self.format.convert(self.width, self.height, pixels);
        frame.dispose = self.disposal;
        frame.delay = delay_cs;
        if self.writer.is_none() {
            let mut writer = gif::Encoder::new(Vec::new(), self.width, self.height, &[])?;
            if let Some(count) = self.loop_count {
                let repeat = if count == 0 {
                    Repeat::Infinite
                } else {
                    Repeat::Finite(count)
                };
                writer.set_repeat(repeat)?;
            }
            self.writer = Some(writer);
        }
        let writer = self.writer.as_mut().expect("writer was initialized");
        writer.write_frame(&frame)?;
        // Drain each chunk; the writer never retains earlier GIF bytes.
        Ok(std::mem::take(writer.get_mut()))
    }

    pub fn finish(&mut self) -> Result<Vec<u8>, EncodingError> {
        match self.writer.take() {
            Some(writer) => writer.into_inner(),
            None => Ok(Vec::new()),
        }
    }
}
