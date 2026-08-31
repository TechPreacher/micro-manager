import XCTest
@testable import WLKit

/// Malformed and extended SGR through `render`. The input is untrusted
/// output from an external binary; a parser that mis-advances either leaks
/// escape bytes into the document or paints the wrong colour.
final class AnsiHTMLEdgeTests: XCTestCase {

    /// No rendering, however mangled the input, may leak a raw escape byte or
    /// leave a span unclosed.
    private func renderChecked(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let html = AnsiHTML.render(text)
        XCTAssertFalse(html.contains("\u{1B}"), "escape byte leaked into the document", file: file, line: line)
        let opens = html.components(separatedBy: "<span").count - 1
        let closes = html.components(separatedBy: "</span>").count - 1
        XCTAssertEqual(opens, closes, "unbalanced spans", file: file, line: line)
        return html
    }

    func testIndexedForegroundThroughRender() {
        XCTAssertEqual(
            renderChecked("\u{1B}[38;5;196mx\u{1B}[0m"),
            "<span style=\"color:#FF0000\">x</span>"
        )
    }

    func testIndexedAndTruecolourBackgrounds() {
        XCTAssertEqual(
            renderChecked("\u{1B}[48;5;21mx\u{1B}[0m"),
            "<span style=\"background:#0000FF\">x</span>"
        )
        XCTAssertEqual(
            renderChecked("\u{1B}[48;2;10;20;30mx\u{1B}[0m"),
            "<span style=\"background:#0A141E\">x</span>"
        )
    }

    func testClassicBackgroundCodes() {
        XCTAssertEqual(
            renderChecked("\u{1B}[41mx\u{1B}[49my"),
            "<span style=\"background:\(AnsiHTML.palette[1])\">x</span>y"
        )
    }

    /// A truncated extended-colour sequence must render the text plainly, not
    /// crash, mis-colour, or leave the escape behind.
    func testTruncatedTruecolourIsIgnored() {
        XCTAssertEqual(renderChecked("\u{1B}[38;2;18mx"), "x")
        XCTAssertEqual(renderChecked("\u{1B}[38mx"), "x")
    }

    func testBareAndEmptyResets() {
        XCTAssertEqual(renderChecked("\u{1B}[31mred\u{1B}[mplain"),
                       "<span style=\"color:\(AnsiHTML.palette[1])\">red</span>plain")
        XCTAssertEqual(renderChecked("\u{1B}[31mred\u{1B}[;;mplain"),
                       "<span style=\"color:\(AnsiHTML.palette[1])\">red</span>plain")
    }

    func testUnknownCodeLeavesStyleAlone() {
        XCTAssertEqual(renderChecked("\u{1B}[999mx"), "x")
    }

    func testAttributeOffCodes() {
        XCTAssertEqual(renderChecked("\u{1B}[1mB\u{1B}[22mN"),
                       "<span class=\"b\">B</span>N")
        XCTAssertEqual(renderChecked("\u{1B}[4mU\u{1B}[24mN"),
                       "<span class=\"u\">U</span>N")
        XCTAssertEqual(renderChecked("\u{1B}[31mc\u{1B}[39mn"),
                       "<span style=\"color:\(AnsiHTML.palette[1])\">c</span>n")
    }

    /// Output truncated mid-escape — a killed process does this — must not
    /// leak the partial escape.
    func testInputEndingMidEscape() {
        XCTAssertEqual(renderChecked("abc\u{1B}"), "abc")
        XCTAssertEqual(renderChecked("abc\u{1B}["), "abc")
        XCTAssertEqual(renderChecked("abc\u{1B}[3"), "abc")
        XCTAssertEqual(renderChecked("abc\u{1B}[38;2;1"), "abc")
    }

    func testEscapeHTMLQuotesAndCarriageReturns() {
        // A bare \r (not the \r\n grapheme) is dropped rather than shown.
        XCTAssertEqual(AnsiHTML.escapeHTML("a\"b<c>&\rx"), "a&quot;b&lt;c&gt;&amp;x")
    }
}
