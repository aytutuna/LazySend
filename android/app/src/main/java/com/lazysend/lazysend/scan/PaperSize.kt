package com.lazysend.lazysend.scan

/** The sheet sizes a page is matched against after it is cut out of a photo; portrait inches. */
enum class PaperSize(val inchesWidth: Double, val inchesHeight: Double) {
    Letter(8.5, 11.0),
    Legal(8.5, 14.0),
    A4(8.2677, 11.6929),
}
