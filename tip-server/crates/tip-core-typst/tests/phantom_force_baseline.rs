//! Investigation: can we force Typst to surface a top-level Group baseline
//! by appending a `hide(x)` phantom to inlined math expressions?
//!
//! Background: bottom-up baseline picking has two paths.
//!  1. `find_outermost_group_baseline` — exact, used when any descendant
//!     Group has `has_baseline()=true`.  Big operators, matrices, sized
//!     delimiters, fractions reliably produce one.
//!  2. Heuristic over text-item y-positions — used when content is
//!     inlined into the page frame without a wrapping math.equation
//!     Group.  Simple accents `hat(x)` and stacked accents
//!     `hat(tilde(phi))` fall here, and the heuristic mispicks among
//!     stacked accents (it grabs the closest-to-page-midpoint y, which
//!     is the middle accent, not the base).
//!
//! Hypothesis: appending `hide(<anchor>)` (e.g. a single letter on the
//! body baseline) forces Typst to lay out the math as a multi-item
//! expression, which (we suspect) causes it to wrap the whole thing in
//! a Group with a real `baseline` field.  The `hide(...)` itself
//! contributes no ink, so post-render cropping makes it invisible.
//!
//! This test does not change the compile pipeline; it just measures.
//! Run: `cargo test -p tip-core-typst --test phantom_force_baseline -- --nocapture`

use typst::layout::{Frame, FrameItem, PagedDocument};
use tip_core_typst::world::TipWorld;

/// Walk the frame tree and find the OUTERMOST Group with has_baseline.
/// Returns (depth_in_tree, absolute_y).  Mirrors the logic in
/// `bottom_up::baseline::find_outermost_group_baseline` so this test
/// reflects what the production path would see.
fn outermost_group_baseline(frame: &Frame, y_offset: f64, depth: usize) -> Option<(usize, f64)> {
    for (pos, item) in frame.items() {
        if let FrameItem::Group(g) = item {
            let gy = y_offset + pos.y.to_pt();
            if g.frame.has_baseline() {
                return Some((depth, gy + g.frame.baseline().to_pt()));
            }
            if let Some(r) = outermost_group_baseline(&g.frame, gy, depth + 1) {
                return Some(r);
            }
        }
    }
    None
}

/// Walk the tree and report all groups with their baseline status.
fn dump_groups(frame: &Frame, y_off: f64, depth: usize, out: &mut Vec<(usize, bool, f64, f64)>) {
    for (pos, item) in frame.items() {
        if let FrameItem::Group(g) = item {
            let gy = y_off + pos.y.to_pt();
            let bl = if g.frame.has_baseline() {
                gy + g.frame.baseline().to_pt()
            } else {
                f64::NAN
            };
            out.push((depth, g.frame.has_baseline(), gy, bl));
            dump_groups(&g.frame, gy, depth + 1, out);
        }
    }
}

/// Collect (text, x, y, size) for every text item.
fn dump_texts(frame: &Frame, x_off: f64, y_off: f64, out: &mut Vec<(String, f64, f64, f64)>) {
    for (pos, item) in frame.items() {
        let ix = x_off + pos.x.to_pt();
        let iy = y_off + pos.y.to_pt();
        match item {
            FrameItem::Text(t) => out.push((t.text.to_string(), ix, iy, t.size.to_pt())),
            FrameItem::Group(g) => dump_texts(&g.frame, ix, iy, out),
            _ => {}
        }
    }
}

struct Probe {
    label: String,
    has_group_baseline: bool,
    group_baseline_y: Option<f64>,
    n_groups: usize,
    n_texts: usize,
    page_width: f64,
    page_height: f64,
    text_y_spread: f64,
}

fn probe(world: &mut TipWorld, label: &str, body: &str) -> Probe {
    let source = format!(
        "#set page(height: auto, width: auto, margin: (top: 20pt, bottom: 20pt, rest: 0pt), fill: none)\n\
         #show math.equation: set text(size: 11pt)\n\
         {body}\n"
    );
    world.set_main_source(&source);
    let doc = typst::compile::<PagedDocument>(world)
        .output
        .unwrap_or_else(|errs| {
            panic!("[{label}] compile failed: {:?}", errs.iter().map(|e| e.message.to_string()).collect::<Vec<_>>())
        });
    let page = &doc.pages[0];

    let mut groups = Vec::new();
    dump_groups(&page.frame, 0.0, 0, &mut groups);
    let mut texts = Vec::new();
    dump_texts(&page.frame, 0.0, 0.0, &mut texts);

    let outer = outermost_group_baseline(&page.frame, 0.0, 0);

    let (y_min, y_max) = texts.iter().fold((f64::INFINITY, f64::NEG_INFINITY), |(lo, hi), &(_, _, y, _)| {
        (lo.min(y), hi.max(y))
    });

    Probe {
        label: label.into(),
        has_group_baseline: outer.is_some(),
        group_baseline_y: outer.map(|(_, y)| y),
        n_groups: groups.len(),
        n_texts: texts.len(),
        page_width: page.frame.width().to_pt(),
        page_height: page.frame.height().to_pt(),
        text_y_spread: if y_min.is_finite() { y_max - y_min } else { 0.0 },
    }
}

fn print_row(p: &Probe) {
    let bl = p.group_baseline_y.map(|v| format!("{:>7.2}", v)).unwrap_or("    nil".into());
    println!(
        "  {:<54} groups={:>2} texts={:>2} w={:>6.2} y_spread={:>5.2}  group_bl={}",
        p.label, p.n_groups, p.n_texts, p.page_width, p.text_y_spread, bl
    );
}

/// Dump the FULL tree (text items + groups, depth-indented) so we can
/// see whether the hide phantom wraps the math, sits alongside it, etc.
fn print_tree(frame: &Frame, x_off: f64, y_off: f64, depth: usize) {
    let indent = "  ".repeat(depth);
    for (pos, item) in frame.items() {
        let ix = x_off + pos.x.to_pt();
        let iy = y_off + pos.y.to_pt();
        match item {
            FrameItem::Text(t) => {
                println!("{indent}TEXT  pos=({ix:>6.2},{iy:>6.2}) size={:>5.2} text={:?}",
                         t.size.to_pt(), t.text.to_string());
            }
            FrameItem::Group(g) => {
                let bl = if g.frame.has_baseline() {
                    format!("{:>6.2}", iy + g.frame.baseline().to_pt())
                } else {
                    "  none".into()
                };
                println!("{indent}GROUP pos=({ix:>6.2},{iy:>6.2}) size=({:>6.2}x{:>5.2}) baseline={bl}",
                         g.frame.width().to_pt(), g.frame.height().to_pt());
                print_tree(&g.frame, ix, iy, depth + 1);
            }
            _ => {}
        }
    }
}

#[test]
fn dump_phantom_tree() {
    let mut world = TipWorld::new();
    let cases = [
        "$tilde(hat(phi))$",
        "$tilde(hat(phi)) #hide[x]$",                // letter phantom — adds visible width pre-crop
        "$tilde(hat(phi)) #hide[#sym.zws]$",         // ZWS phantom — zero-width
        "$phi$",
        "$phi #hide[#sym.zws]$",                     // does ZWS phantom take on single-glyph?
        "$a + b$",
        "$a + b #hide[#sym.zws]$",
    ];
    for src in &cases {
        let preamble = "#set page(height: auto, width: auto, margin: (top: 20pt, bottom: 20pt, rest: 0pt), fill: none)\n#show math.equation: set text(size: 11pt)\n";
        world.set_main_source(&format!("{preamble}{src}\n"));
        let doc = typst::compile::<PagedDocument>(&mut world).output.unwrap();
        let page = &doc.pages[0];
        println!("\n=== {src} ===  page=({:.2}x{:.2})\n", page.frame.width().to_pt(), page.frame.height().to_pt());
        print_tree(&page.frame, 0.0, 0.0, 0);
    }
}

/// Bottom margin (pt) used by the test render config — the same 20pt
/// the production bottom-up path uses.
const BOTTOM_MARGIN_PT: f64 = 20.0;

/// The body baseline of any frame produced by our test config sits at
/// `page_height - BOTTOM_MARGIN_PT` (Typst trims auto-height pages so
/// the body line bottoms out flush with the bottom margin).  This is
/// what `find_outermost_group_baseline' must return for an
/// inline-math fragment we can correctly position on the host text
/// baseline.  Specific number depends on the math content (taller
/// content like `|(y)|` gives a taller page, hence a deeper baseline).
fn expected_body_baseline(page_height_pt: f64) -> f64 {
    page_height_pt - BOTTOM_MARGIN_PT
}

#[test]
fn phantom_force_group_baseline() {
    let mut world = TipWorld::new();

    println!("\n=== Plain vs `#hide[#sym.zws]` suffix ===\n");

    // Cases that CLAUDE.md flags as "inlined → heuristic", plus the
    // stacked-accent class that motivated this whole investigation.
    let must_unlock_baseline: &[&str] = &[
        "a + b",
        "a_b",
        "a^2",
        "sqrt(x)",
        "tilde(a)",
        "hat(a)",
        "abs(x)",
        "hat(tilde(phi))",
        "hat(hat(x))",
        "tilde(hat(phi))",
        "dot(dot(x))",
        "hat(tilde(bar(dot(z))))",
    ];

    for expr in must_unlock_baseline {
        let raw_src = format!("${expr}$");
        let raw = probe(&mut world, &raw_src, &raw_src);
        let aug_src = format!("${expr} #hide[#sym.zws]$");
        let aug = probe(&mut world, &aug_src, &aug_src);
        print_row(&raw);
        print_row(&aug);
        println!();

        // Property 1: the phantom MUST produce a group baseline equal
        // to the body baseline of the augmented frame
        // (page_height - bottom_margin).
        assert!(
            aug.has_group_baseline,
            "[{expr}] phantom failed to produce a group baseline"
        );
        let bl = aug.group_baseline_y.unwrap();
        let want = expected_body_baseline(aug.page_height);
        assert!(
            (bl - want).abs() < 0.1,
            "[{expr}] expected baseline ~{want:.2} (= {:.2} - {BOTTOM_MARGIN_PT}), got {bl:.2}",
            aug.page_height
        );

        // Property 2: ZWS phantom must NOT inflate page width
        // (zero-width by construction).  This is what makes ZWS strictly
        // better than `#hide[x]` — no SVG width waste, no cropping
        // concerns.
        assert!(
            (raw.page_width - aug.page_width).abs() < 0.1,
            "[{expr}] ZWS phantom inflated width: raw={:.2} aug={:.2}",
            raw.page_width, aug.page_width
        );
    }

    println!("\n=== Cases that already produced a group baseline ===\n");
    let already_have_baseline: &[&str] = &[
        "sum_(i=0)^n",
        "integral_0^1 f",
        "mat(1,0;0,1)",
        "(a+b)/(c+d)",
        "lr([1/q])",
        "tilde(hat(tilde(phi)))",
    ];
    for expr in already_have_baseline {
        let raw_src = format!("${expr}$");
        let raw = probe(&mut world, &raw_src, &raw_src);
        let aug_src = format!("${expr} #hide[#sym.zws]$");
        let aug = probe(&mut world, &aug_src, &aug_src);
        print_row(&raw);
        print_row(&aug);
        println!();

        // Property 3: phantom must not BREAK an already-correct
        // baseline.  Group baseline before == after.
        assert!(raw.has_group_baseline && aug.has_group_baseline,
                "[{expr}] expected group baseline both before and after");
        let (b0, b1) = (raw.group_baseline_y.unwrap(), aug.group_baseline_y.unwrap());
        assert!(
            (b0 - b1).abs() < 0.1,
            "[{expr}] phantom shifted baseline: {b0:.2} -> {b1:.2}"
        );
    }

    println!("\n=== Single-glyph case ($phi$) — phantom does NOT take ===\n");
    // Single-text-item math is a known phantom-resistant case.  The
    // production `find_baseline_depth' has a 1-text-item fallback:
    // when no group baseline is found and there's exactly one text
    // item, return its y (which is the baseline by definition for a
    // single glyph).  Documented here so future readers know the
    // phantom isn't expected to help here.
    let single = probe(&mut world, "$phi #hide[#sym.zws]$", "$phi #hide[#sym.zws]$");
    print_row(&single);
    assert!(
        !single.has_group_baseline,
        "single-glyph phantom unexpectedly produced a group — \
         the 1-text-item fallback in find_baseline_depth may be removable"
    );
}
