use hara_wasm::core::Value;
use hara_wasm::hta;
use sha2::{Digest, Sha256};
use std::cell::RefCell;
use std::collections::VecDeque;

thread_local! {
    static EVENTS: RefCell<VecDeque<Vec<u8>>> = RefCell::new(VecDeque::new());
    static NEXT_TASK: RefCell<u64> = const { RefCell::new(1) };
}

#[no_mangle]
pub extern "C" fn hta_abi_version() -> i32 { 1 }

#[no_mangle]
pub extern "C" fn hta_alloc(size: usize) -> *mut u8 {
    unsafe { std::alloc::alloc(std::alloc::Layout::from_size_align(size.max(1), 1).unwrap()) }
}

#[no_mangle]
pub extern "C" fn hta_dealloc(pointer: *mut u8, size: usize) {
    if !pointer.is_null() {
        unsafe { std::alloc::dealloc(pointer, std::alloc::Layout::from_size_align(size.max(1), 1).unwrap()) }
    }
}

fn request(bytes: &[u8]) -> Result<Vec<u8>, String> {
    match hta::decode(bytes)? {
        Value::Vector(values) if values.len() == 2
            && matches!(&values[0], Value::String(target) if target == "digest") =>
        {
            match &values[1] {
                Value::Vector(arguments) if arguments.len() == 1 => match &arguments[0] {
                    Value::Bytes(bytes) => Ok(bytes.clone()),
                    Value::ByteBuffer(bytes) => Ok(bytes.borrow().clone()),
                    _ => Err("ignatius.extension.sha/digest expects bytes".into()),
                },
                _ => Err("ignatius.extension.sha/digest expects one argument".into()),
            }
        }
        _ => Err("hta/start expects [\"digest\" [bytes]]".into()),
    }
}

fn error(message: String) -> Value {
    Value::Map(vec![
        (Value::Keyword("code".into()), Value::Keyword("sha/digest-failed".into())),
        (Value::Keyword("message".into()), Value::String(message)),
        (Value::Keyword("origin".into()), Value::Keyword("wasm".into())),
        (Value::Keyword("retryable".into()), Value::Bool(false)),
    ].into_iter().collect())
}

#[no_mangle]
pub extern "C" fn hta_start(pointer: *const u8, size: usize) -> i64 {
    let bytes = if pointer.is_null() { &[][..] } else { unsafe { std::slice::from_raw_parts(pointer, size) } };
    let task = NEXT_TASK.with(|next| { let task = *next.borrow(); *next.borrow_mut() += 1; task });
    let (kind, value) = match request(bytes) {
        Ok(bytes) => (0, Value::Bytes(Sha256::digest(bytes).to_vec())),
        Err(message) => (1, error(message)),
    };
    if let Ok(frame) = hta::encode(&Value::Vector(vec![Value::Number(kind), Value::Number(task as i64), value].into())) {
        EVENTS.with(|events| events.borrow_mut().push_back(frame));
    }
    task as i64
}

fn output(bytes: Vec<u8>) -> i64 {
    let size = bytes.len();
    let pointer = hta_alloc(size);
    if pointer.is_null() { return 0; }
    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), pointer, size); }
    (((pointer as u64) << 32) | size as u64) as i64
}

#[no_mangle]
pub extern "C" fn hta_next_event() -> i64 { EVENTS.with(|events| events.borrow_mut().pop_front().map(output).unwrap_or(0)) }
#[no_mangle]
pub extern "C" fn hta_poll() -> i32 { EVENTS.with(|events| events.borrow().len() as i32) }
#[no_mangle]
pub extern "C" fn hta_deliver(_pointer: *const u8, _size: usize) -> i32 { 1 }
#[no_mangle]
pub extern "C" fn hta_cancel(_task: i64) -> i32 { 1 }
#[no_mangle]
pub extern "C" fn hta_drop_task(_task: i64) -> i32 { 0 }
#[no_mangle]
pub extern "C" fn hta_release(_pointer: *const u8, _size: usize) -> i32 { 0 }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_vector() {
        assert_eq!(
            Sha256::digest(b"abc").as_slice(),
            [
                0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
                0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
                0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
                0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
            ]
        );
    }
}
