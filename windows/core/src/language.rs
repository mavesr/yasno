#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Language { English, German, Russian, Ukrainian }

impl Language {
    pub const ALL: [Language; 4] = [Language::English, Language::German, Language::Russian, Language::Ukrainian];

    pub fn code(self) -> &'static str {
        match self { Language::English => "en", Language::German => "de", Language::Russian => "ru", Language::Ukrainian => "uk" }
    }

    pub fn is_cyrillic(self) -> bool { matches!(self, Language::Russian | Language::Ukrainian) }

    /// The languages a Windows keyboard layout writes, from the primary language of its
    /// LANGID (the low word of an HKL). English and German share the Latin layouts, as
    /// ABC and German QWERTZ do on the Mac: the order matches the Mac version.
    pub fn for_windows_langid(langid: u16) -> Option<Vec<Language>> {
        match langid & 0x3ff {
            0x09 => Some(vec![Language::English, Language::German]),
            0x07 => Some(vec![Language::German, Language::English]),
            0x19 => Some(vec![Language::Russian]),
            0x22 => Some(vec![Language::Ukrainian]),
            _ => None,
        }
    }
}
