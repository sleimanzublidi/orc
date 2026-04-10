import Foundation
import Testing
@testable import CLI
import Models

// MARK: - Duration Formatting

@Suite("Format.duration")
struct FormatDurationTests {

    // Sub-second values: should display in milliseconds

    @Test("0 seconds formats as 0ms")
    func zeroSeconds() {
        #expect(Format.duration(0) == "0ms")
    }

    @Test("sub-second value formats as milliseconds")
    func subSecond() {
        #expect(Format.duration(0.5) == "500ms")
    }

    @Test("very small value formats as milliseconds")
    func verySmall() {
        #expect(Format.duration(0.001) == "1ms")
    }

    @Test("value just below 1s formats as milliseconds")
    func justBelowOneSecond() {
        #expect(Format.duration(0.999) == "999ms")
    }

    // Seconds range: 1s ..< 60s

    @Test("exactly 1 second formats as seconds with one decimal")
    func exactlyOneSecond() {
        #expect(Format.duration(1.0) == "1.0s")
    }

    @Test("fractional seconds format with one decimal")
    func fractionalSeconds() {
        #expect(Format.duration(30.7) == "30.7s")
    }

    @Test("value just below 60s formats as seconds")
    func justBelowOneMinute() {
        #expect(Format.duration(59.9) == "59.9s")
    }

    // Minutes range: 60s ..< 3600s

    @Test("exactly 60 seconds formats as minutes and seconds")
    func exactlyOneMinute() {
        #expect(Format.duration(60) == "1m 0s")
    }

    @Test("90 seconds formats as 1m 30s")
    func ninetySeconds() {
        #expect(Format.duration(90) == "1m 30s")
    }

    @Test("value just below 3600s formats as minutes and seconds")
    func justBelowOneHour() {
        #expect(Format.duration(3599) == "59m 59s")
    }

    // Hours range: >= 3600s

    @Test("exactly 3600 seconds formats as hours and minutes")
    func exactlyOneHour() {
        #expect(Format.duration(3600) == "1h 0m")
    }

    @Test("mixed hours and minutes")
    func mixedHoursMinutes() {
        #expect(Format.duration(5400) == "1h 30m")
    }

    @Test("large value formats as hours and minutes")
    func largeValue() {
        // 2h 15m = 8100s
        #expect(Format.duration(8100) == "2h 15m")
    }
}

// MARK: - File Size Formatting

@Suite("Format.fileSize")
struct FormatFileSizeTests {

    // Bytes range: < 1024

    @Test("0 bytes")
    func zeroBytes() {
        #expect(Format.fileSize(0) == "0 B")
    }

    @Test("small byte count")
    func smallBytes() {
        #expect(Format.fileSize(512) == "512 B")
    }

    @Test("value just below 1 KB")
    func justBelowOneKB() {
        #expect(Format.fileSize(1023) == "1023 B")
    }

    // Kilobytes range: 1024 ..< 1MB

    @Test("exactly 1 KB")
    func exactlyOneKB() {
        #expect(Format.fileSize(1024) == "1.0 KB")
    }

    @Test("fractional KB value")
    func fractionalKB() {
        // 1536 bytes = 1.5 KB
        #expect(Format.fileSize(1536) == "1.5 KB")
    }

    @Test("value just below 1 MB")
    func justBelowOneMB() {
        // 1048575 = 1024*1024 - 1 = 1023.999... KB
        #expect(Format.fileSize(1_048_575) == "1024.0 KB")
    }

    // Megabytes range: 1MB ..< 1GB

    @Test("exactly 1 MB")
    func exactlyOneMB() {
        #expect(Format.fileSize(1_048_576) == "1.0 MB")
    }

    @Test("fractional MB value")
    func fractionalMB() {
        // 5 * 1024 * 1024 = 5242880
        #expect(Format.fileSize(5_242_880) == "5.0 MB")
    }

    @Test("value just below 1 GB")
    func justBelowOneGB() {
        // 1073741823 = 1024*1024*1024 - 1 = 1024.0 MB (rounds)
        #expect(Format.fileSize(1_073_741_823) == "1024.0 MB")
    }

    // Gigabytes range: >= 1GB

    @Test("exactly 1 GB")
    func exactlyOneGB() {
        #expect(Format.fileSize(1_073_741_824) == "1.0 GB")
    }

    @Test("fractional GB value")
    func fractionalGB() {
        // 2.5 GB = 2684354560
        #expect(Format.fileSize(2_684_354_560) == "2.5 GB")
    }
}

// MARK: - Status Indicator Formatting

@Suite("Format.statusIndicator")
struct FormatStatusIndicatorTests {

    @Test("pending status")
    func pending() {
        #expect(Format.statusIndicator(.pending) == "[pending]")
    }

    @Test("running status")
    func running() {
        #expect(Format.statusIndicator(.running) == "[running]")
    }

    @Test("awaitingInput status uses raw value")
    func awaitingInput() {
        #expect(Format.statusIndicator(.awaitingInput) == "[awaiting_input]")
    }

    @Test("completed status")
    func completed() {
        #expect(Format.statusIndicator(.completed) == "[completed]")
    }

    @Test("failed status")
    func failed() {
        #expect(Format.statusIndicator(.failed) == "[failed]")
    }

    @Test("cancelled status")
    func cancelled() {
        #expect(Format.statusIndicator(.cancelled) == "[cancelled]")
    }
}

// MARK: - Node Status Indicator Formatting

@Suite("Format.nodeStatusIndicator")
struct FormatNodeStatusIndicatorTests {

    @Test("pending node status")
    func pending() {
        #expect(Format.nodeStatusIndicator(.pending) == "[pending]")
    }

    @Test("running node status")
    func running() {
        #expect(Format.nodeStatusIndicator(.running) == "[running]")
    }

    @Test("awaitingInput node status uses raw value")
    func awaitingInput() {
        #expect(Format.nodeStatusIndicator(.awaitingInput) == "[awaiting_input]")
    }

    @Test("completed node status")
    func completed() {
        #expect(Format.nodeStatusIndicator(.completed) == "[completed]")
    }

    @Test("failed node status")
    func failed() {
        #expect(Format.nodeStatusIndicator(.failed) == "[failed]")
    }

    @Test("skipped node status")
    func skipped() {
        #expect(Format.nodeStatusIndicator(.skipped) == "[skipped]")
    }

    @Test("cancelled node status")
    func cancelled() {
        #expect(Format.nodeStatusIndicator(.cancelled) == "[cancelled]")
    }
}
