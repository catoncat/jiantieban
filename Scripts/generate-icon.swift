#!/usr/bin/env swift
// 生成一个占位 App 图标（1024x1024 PNG）：蓝色玻璃圆角 + 白色剪贴板。
// 用法: swift Scripts/generate-icon.swift [output.png]
import AppKit
import Foundation

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "build/AppIcon.png"

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

// 背景：深蓝 → 蓝紫渐变圆角方块
let canvas = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 1024, height: 1024), xRadius: 220, yRadius: 220)
NSGradient(colors: [NSColor.systemBlue, NSColor.systemIndigo])?.draw(in: canvas, angle: -45)

// 白色剪贴板主体
let boardRect = NSRect(x: 320, y: 230, width: 384, height: 520)
let board = NSBezierPath(roundedRect: boardRect, xRadius: 72, yRadius: 72)
NSColor.white.setFill()
board.fill()

// 顶部夹子
let clipRect = NSRect(x: 400, y: 680, width: 224, height: 96)
let clip = NSBezierPath(roundedRect: clipRect, xRadius: 40, yRadius: 40)
NSColor.systemBlue.setFill()
clip.fill()

// 三条“文字行”
let lineColor = NSColor.systemBlue.withAlphaComponent(0.85)
for (index, y) in [540.0, 450.0, 360.0].enumerated() {
    let width = index == 1 ? 220.0 : 260.0
    let line = NSBezierPath(roundedRect: NSRect(x: 382, y: y, width: width, height: 36), xRadius: 18, yRadius: 18)
    lineColor.setFill()
    line.fill()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("failed to render icon\n", stderr)
    exit(1)
}

let outURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: outURL)
print("wrote \(outputPath)")
