use std::sync::Mutex;

use rustler::{Atom, Binary, Encoder as _, Env, NifResult, OwnedBinary, ResourceArc, Term};

use crate::encoder::Encoder;
use crate::pixels::PixelFormat;

mod atoms {
    rustler::atoms! {
        ok,
        error
    }
}

// ResourceArc provides shared access; the GIF writer requires exclusive mutable access.
struct EncoderResource(Mutex<Encoder>);

#[derive(rustler::NifMap)]
struct CreateOptions {
    width: u64,
    height: u64,
    pixel_format: Atom,
    r#loop: Option<u64>,
}

#[allow(non_local_definitions)]
fn load(env: Env, _info: Term) -> bool {
    rustler::resource!(EncoderResource, env)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn create(env: Env, options: CreateOptions) -> NifResult<Term> {
    // Rustler 0.34 narrows u16 arguments with a cast. Use checked conversions here.
    let width = u16::try_from(options.width).map_err(|_| rustler::Error::BadArg)?;
    let height = u16::try_from(options.height).map_err(|_| rustler::Error::BadArg)?;
    let loop_count = options
        .r#loop
        .map(u16::try_from)
        .transpose()
        .map_err(|_| rustler::Error::BadArg)?;
    let Ok(format) = options.pixel_format.encode(env).decode::<PixelFormat>() else {
        return Ok((atoms::error(), "unsupported_pixel_format").encode(env));
    };
    let encoder = Encoder::new(width, height, format, loop_count);
    Ok((
        atoms::ok(),
        ResourceArc::new(EncoderResource(Mutex::new(encoder))),
    )
        .encode(env))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn encode<'a>(
    env: Env<'a>,
    resource: ResourceArc<EncoderResource>,
    pixels: Binary,
    delay_cs: u64,
) -> NifResult<Term<'a>> {
    let delay_cs = u16::try_from(delay_cs).map_err(|_| rustler::Error::BadArg)?;
    let output = resource
        .0
        .lock()
        .map_err(|_| rustler::Error::BadArg)?
        .encode(&pixels, delay_cs);
    output_term(env, output)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn finish<'a>(env: Env<'a>, resource: ResourceArc<EncoderResource>) -> NifResult<Term<'a>> {
    let output = resource
        .0
        .lock()
        .map_err(|_| rustler::Error::BadArg)?
        .finish();
    output_term(env, output)
}

fn output_term(env: Env, output: Result<Vec<u8>, String>) -> NifResult<Term> {
    match output {
        Ok(bytes) => {
            let mut payload = OwnedBinary::new(bytes.len()).ok_or(rustler::Error::BadArg)?;
            payload.as_mut_slice().copy_from_slice(&bytes);
            Ok((atoms::ok(), payload.release(env)).encode(env))
        }
        Err(error) => Ok((atoms::error(), error).encode(env)),
    }
}

rustler::init!("Elixir.Membrane.GIF.Encoder.Native", load = load);
