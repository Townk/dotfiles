// Probe: can a plain non-GUI process convert HTML and RTF to plain text?
//
// restore_plain_by_id falls back to hs.styledtext.getStyledTextFromData(...)
// :convert("text") when a row has no text_plain. Natively that is
// NSAttributedString(data:options:documentAttributes:), whose HTML importer is
// WebKit-backed and is documented as main-thread-only -- the one API in the
// absorbed set with a real chance of failing outside a GUI app.

use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::AllocAnyThread;
use objc2_app_kit::{NSAttributedStringDocumentFormats, NSDocumentTypeDocumentAttribute,
    NSHTMLTextDocumentType, NSRTFTextDocumentType};
use objc2_foundation::NSAttributedString;
use objc2_foundation::{NSData, NSDictionary, NSString};

fn main() {
    let types: [(&str, Vec<u8>, &NSString); 2] = unsafe {
        [
            ("html", b"<b>hi</b> &amp; bye".to_vec(), std::mem::transmute::<_, &NSString>(&**NSHTMLTextDocumentType)),
            (
                "rtf",
                br"{\rtf1\ansi{\fonttbl\f0\fswiss Helvetica;}\f0\pard hello rtf\par}".to_vec(),
                std::mem::transmute::<_, &NSString>(&**NSRTFTextDocumentType),
            ),
        ]
    };
    for (label, bytes, doctype) in types {
        let data = NSData::with_bytes(&bytes);
        let key: &NSString = unsafe { std::mem::transmute(&**NSDocumentTypeDocumentAttribute) };
        let val = doctype;
        let opts: Retained<NSDictionary<NSString, AnyObject>> =
            NSDictionary::from_slices(&[key], &[val as &AnyObject]);

        let res = unsafe {
            NSAttributedString::initWithData_options_documentAttributes_error(
                NSAttributedString::alloc(),
                &data,
                std::mem::transmute::<&NSDictionary<NSString, AnyObject>, &NSDictionary<_, _>>(
                    &opts,
                ),
                None,
            )
        };
        match res {
            Ok(s) => println!("Q9 {label} ({}) -> {:?}", doctype.to_string(), s.string().to_string()),
            Err(e) => println!("Q9 {label} -> ERROR {e:?}"),
        }
    }
}
