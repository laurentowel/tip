use typst::foundations::{Content, Smart};
use typst::layout::{Frame, Sides};
use typst_layout::Page;
use typst_svg::{svg, SvgOptions};

pub(crate) fn svg_frame(frame: &Frame) -> String {
    let page = Page {
        frame: frame.clone(),
        bleed: Sides::default(),
        fill: Smart::Custom(None),
        numbering: None,
        supplement: Content::empty(),
        number: 1,
    };

    svg(&page, &SvgOptions::default())
}
