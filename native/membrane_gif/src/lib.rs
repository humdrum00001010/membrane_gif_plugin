mod encoder;
mod pixels;

// Cargo tests exercise the backend; ExUnit exercises the loaded NIF.
#[cfg(not(test))]
mod nif;
