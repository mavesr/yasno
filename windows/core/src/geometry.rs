//! Physical key positions of an ISO keyboard by scan code. A slip to the next key is the
//! same finger motion in every layout, so the spelling corrector weighs slips here,
//! below the layout.

use std::collections::HashMap;
use std::sync::OnceLock;

const ROWS: [(f64, &[u16]); 4] = [
    (0.0, &[0x29, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D]), // ` 1 2 … - =
    (1.5, &[0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B]),       // q w e … [ ]
    (1.75, &[0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2B]),      // a s d … ; ' #
    (1.25, &[0x56, 0x2C, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35]),            // \ z x … , . /
];

fn neighbours() -> &'static HashMap<u16, Vec<u16>> {
    static MAP: OnceLock<HashMap<u16, Vec<u16>>> = OnceLock::new();
    MAP.get_or_init(|| {
        let mut positions = HashMap::new();
        for (row, (offset, keys)) in ROWS.iter().enumerate() {
            for (i, &key) in keys.iter().enumerate() { positions.insert(key, (row as i32, offset + i as f64)); }
        }
        positions.iter().map(|(&key, &(row, x))| {
            let mut near: Vec<u16> = positions.iter()
                .filter(|(&k, &(r, kx))| k != key && (row - r).abs() <= 1 && (x - kx).abs() <= 1.0001)
                .map(|(&k, _)| k).collect();
            near.sort_unstable();
            (key, near)
        }).collect()
    })
}

pub fn are_neighbours(a: u16, b: u16) -> bool {
    neighbours().get(&a).is_some_and(|n| n.contains(&b))
}
