/// A complete cycle, optionally starting with a language inferred for the first conversion.
/// Subsequent presses always visit the remaining layouts rather than undoing back and forth.
#[derive(Clone, Debug)]
pub struct LayoutCycle { pub layout_ids: Vec<String> }

impl LayoutCycle {
    pub fn new(layout_ids: &[String], starting_id: Option<&str>, first_target_id: Option<&str>) -> Self {
        let mut unique: Vec<String> = Vec::new();
        for id in layout_ids { if !unique.contains(id) { unique.push(id.clone()); } }
        let mut ordered: Vec<String> = Vec::new();
        if let Some(s) = starting_id { if unique.iter().any(|u| u == s) { ordered.push(s.into()); } }
        if let Some(f) = first_target_id {
            if unique.iter().any(|u| u == f) && !ordered.iter().any(|o| o == f) { ordered.push(f.into()); }
        }
        let rest: Vec<String> = unique.into_iter().filter(|u| !ordered.contains(u)).collect();
        ordered.extend(rest);
        LayoutCycle { layout_ids: ordered }
    }

    pub fn next(&self, current_id: &str) -> Option<&str> {
        if self.layout_ids.len() <= 1 { return None; }
        match self.layout_ids.iter().position(|i| i == current_id) {
            None => self.layout_ids.first().map(String::as_str),
            Some(i) => Some(&self.layout_ids[(i + 1) % self.layout_ids.len()]),
        }
    }
}
