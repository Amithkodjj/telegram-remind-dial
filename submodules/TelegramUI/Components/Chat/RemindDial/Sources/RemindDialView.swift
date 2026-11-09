import Foundation
import UIKit
import QuartzCore
import Metal
import simd

private func designedFont(_ size: CGFloat, _ weight: UIFont.Weight, _ design: UIFontDescriptor.SystemDesign) -> UIFont {
    let base = UIFont.systemFont(ofSize: size, weight: weight)
    if let descriptor = base.fontDescriptor.withDesign(design) {
        return UIFont(descriptor: descriptor, size: size)
    }
    return base
}

private func mixColor(_ a: (CGFloat, CGFloat, CGFloat), _ b: (CGFloat, CGFloat, CGFloat), _ t: CGFloat, _ alpha: CGFloat = 1.0) -> CGColor {
    return UIColor(red: a.0 + (b.0 - a.0) * t, green: a.1 + (b.1 - a.1) * t, blue: a.2 + (b.2 - a.2) * t, alpha: alpha).cgColor
}

private final class RemindDisplayLinkTarget: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func fire() {
        self.action()
    }
}

public final class RemindDialView: UIView, UIGestureRecognizerDelegate {
    public var onCommit: ((Date, String) -> Void)?
    public var onFinished: (() -> Void)?

    public static func prewarm() {
        RemindSkyRenderer.load { _ in }
    }

    private static let trackDepth: CGFloat = 30.0
    private static let romans = ["XII", "I", "II", "III", "IIII", "V", "VI", "VII", "VIII", "IX", "X", "XI"]

    private let safeInsets: UIEdgeInsets
    private let snapshot: CGImage?
    private let snapshotFrame: CGRect

    private let skyLayer = CAMetalLayer()
    private var renderer: RemindSkyRenderer?
    private var link: CADisplayLink?

    private let headingLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let messageView = UIImageView()
    private let dialView = UIView()
    private let plateLayer = CAShapeLayer()
    private var goldLayers: [CAGradientLayer] = []
    private let beadsLayer = CAShapeLayer()
    private let minorTicksLayer = CAShapeLayer()
    private let arcContainer = CAGradientLayer()
    private let arcMask = CAShapeLayer()
    private let collarLayer = CAShapeLayer()
    private let nowLayer = CAShapeLayer()
    private let knobHole = CAShapeLayer()
    private var numeralLabels: [UILabel] = []
    private let dayLabel = UILabel()
    private let timeLabel = UILabel()
    private let relativeLabel = UILabel()
    private let chipsScroll = UIScrollView()
    private var chips: [(button: UIButton, minute: Int)] = []
    private let confirmButton = UIButton(type: .custom)
    private let clockView = UIView()
    private let pickerPanel = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
    private let datePicker = UIDatePicker()

    private let calendar = Calendar.current
    private let startOfToday: Date
    private let nowMinute: CGFloat
    private let minimumMinute: CGFloat
    private let maximumMinute: CGFloat
    private var minute: CGFloat
    private var exactMinute: Int?
    private var steppedMinute: Int = -1

    private var dialCenter: CGPoint = .zero
    private var radius: CGFloat = 0.0
    private var lastAngle: CGFloat = 0.0
    private var isDragging = false
    private var isClosing = false
    private var isPickerOpen = false

    private var clock: Double = 0.0
    private var lastTick: CFTimeInterval = 0.0
    private var previousMinute: CGFloat = 0.0
    private var spin: CGFloat = 0.0
    private var speed: CGFloat = 0.0
    private var tilt = CGPoint.zero
    private var knobPoint = CGPoint.zero
    private var knobScale: CGFloat = 1.0
    private var shortcutFrom: CGFloat = 0.0
    private var shortcutTo: CGFloat?
    private var shortcutStart: CFTimeInterval = 0.0

    private let tickFeedback = UISelectionFeedbackGenerator()
    private let hourFeedback = UIImpactFeedbackGenerator(style: .light)
    private let commitFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
    private let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter
    }()
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter
    }()

    public init(frame: CGRect, safeInsets: UIEdgeInsets, snapshot: CGImage?, snapshotFrame: CGRect) {
        self.safeInsets = safeInsets
        self.snapshot = snapshot
        self.snapshotFrame = snapshotFrame

        let now = Date()
        self.startOfToday = Calendar.current.startOfDay(for: now)
        self.nowMinute = CGFloat(now.timeIntervalSince(self.startOfToday) / 60.0)
        self.minimumMinute = ceil((self.nowMinute + 5.0) / 5.0) * 5.0
        self.maximumMinute = self.nowMinute + 365.0 * 1440.0
        self.minute = ceil((self.nowMinute + 60.0) / 5.0) * 5.0

        super.init(frame: frame)
        self.previousMinute = self.minute
        self.alpha = 0.0
        self.build()
        self.applyMinute(haptics: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.link?.invalidate()
    }

    private func build() {
        let width = self.bounds.width
        let height = self.bounds.height
        let scale = min(UIScreen.main.scale, 2.0)

        self.skyLayer.frame = self.bounds
        self.skyLayer.pixelFormat = .bgra8Unorm
        self.skyLayer.framebufferOnly = true
        self.skyLayer.isOpaque = true
        self.skyLayer.contentsScale = scale
        self.skyLayer.drawableSize = CGSize(width: width * scale, height: height * scale)
        self.layer.addSublayer(self.skyLayer)

        self.headingLabel.attributedText = NSAttributedString(string: "REMIND ME", attributes: [.kern: 3.0, .font: UIFont.systemFont(ofSize: 13.0, weight: .semibold), .foregroundColor: UIColor.white])
        self.headingLabel.textAlignment = .center
        self.headingLabel.frame = CGRect(x: 70.0, y: self.safeInsets.top + 10.0, width: width - 140.0, height: 28.0)
        self.headingLabel.layer.shadowColor = UIColor.black.cgColor
        self.headingLabel.layer.shadowOpacity = 0.35
        self.headingLabel.layer.shadowRadius = 6.0
        self.headingLabel.layer.shadowOffset = .zero
        self.addSubview(self.headingLabel)

        self.closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14.0, weight: .semibold)), for: .normal)
        self.closeButton.tintColor = .white
        self.closeButton.backgroundColor = UIColor(white: 0.0, alpha: 0.28)
        self.closeButton.layer.cornerRadius = 19.0
        self.closeButton.frame = CGRect(x: 18.0, y: self.safeInsets.top + 5.0, width: 38.0, height: 38.0)
        self.closeButton.addTarget(self, action: #selector(self.closePressed), for: .touchUpInside)
        self.addSubview(self.closeButton)

        if let snapshot = self.snapshot {
            self.messageView.image = UIImage(cgImage: snapshot, scale: UIScreen.main.scale, orientation: .up)
            self.messageView.frame = self.snapshotFrame
            self.messageView.layer.shadowColor = UIColor.black.cgColor
            self.messageView.layer.shadowOpacity = 0.4
            self.messageView.layer.shadowRadius = 22.0
            self.messageView.layer.shadowOffset = CGSize(width: 0.0, height: 12.0)
            self.addSubview(self.messageView)
        }

        self.radius = min(width * 0.345, 145.0)
        self.dialCenter = CGPoint(x: width * 0.5, y: height * 0.515)
        let side = (self.radius + 44.0) * 2.0
        self.dialView.frame = CGRect(x: self.dialCenter.x - side * 0.5, y: self.dialCenter.y - side * 0.5, width: side, height: side)
        self.addSubview(self.dialView)
        self.buildDial(side: side)

        self.chipsScroll.frame = CGRect(x: 0.0, y: self.dialCenter.y + self.radius + 42.0, width: width, height: 42.0)
        self.chipsScroll.showsHorizontalScrollIndicator = false
        self.addSubview(self.chipsScroll)
        self.buildChips(width: width)

        let buttonHeight: CGFloat = 56.0
        self.confirmButton.frame = CGRect(x: 20.0, y: height - max(self.safeInsets.bottom, 16.0) - 10.0 - buttonHeight, width: width - 40.0, height: buttonHeight)
        self.confirmButton.backgroundColor = .white
        self.confirmButton.layer.cornerRadius = buttonHeight * 0.5
        self.confirmButton.layer.shadowColor = UIColor.black.cgColor
        self.confirmButton.layer.shadowOpacity = 0.3
        self.confirmButton.layer.shadowRadius = 20.0
        self.confirmButton.layer.shadowOffset = CGSize(width: 0.0, height: 8.0)
        self.confirmButton.setTitleColor(UIColor(red: 0.06, green: 0.08, blue: 0.18, alpha: 1.0), for: .normal)
        self.confirmButton.titleLabel?.font = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
        self.confirmButton.titleLabel?.adjustsFontSizeToFitWidth = true
        self.confirmButton.titleLabel?.minimumScaleFactor = 0.75
        self.confirmButton.addTarget(self, action: #selector(self.confirmPressed), for: .touchUpInside)
        self.confirmButton.addTarget(self, action: #selector(self.confirmDown), for: [.touchDown, .touchDragEnter])
        self.confirmButton.addTarget(self, action: #selector(self.confirmUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        self.addSubview(self.confirmButton)

        self.buildPickerPanel(width: width, height: height)

        self.clockView.frame = CGRect(x: width * 0.5 - 24.0, y: self.safeInsets.top + 2.0, width: 48.0, height: 48.0)
        self.clockView.layer.cornerRadius = 24.0
        self.clockView.backgroundColor = UIColor(white: 1.0, alpha: 0.22)
        self.clockView.alpha = 0.0
        let alarm = UIImageView(image: UIImage(systemName: "alarm.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 21.0, weight: .semibold)))
        alarm.tintColor = .white
        alarm.center = CGPoint(x: 24.0, y: 24.0)
        self.clockView.addSubview(alarm)
        self.addSubview(self.clockView)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(self.handlePan(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        self.addGestureRecognizer(pan)
    }

    private func addGoldRing(radius ringRadius: CGFloat, lineWidth: CGFloat, zPosition: CGFloat, center: CGPoint, side: CGFloat) {
        let mask = CAShapeLayer()
        mask.frame = CGRect(x: 0.0, y: 0.0, width: side, height: side)
        mask.path = UIBezierPath(arcCenter: center, radius: ringRadius, startAngle: 0.0, endAngle: .pi * 2.0, clockwise: true).cgPath
        mask.fillColor = nil
        mask.strokeColor = UIColor.white.cgColor
        mask.lineWidth = lineWidth

        let gold = CAGradientLayer()
        gold.type = .conic
        gold.frame = CGRect(x: 0.0, y: 0.0, width: side, height: side)
        gold.startPoint = CGPoint(x: 0.5, y: 0.5)
        gold.endPoint = CGPoint(x: 0.5, y: 0.0)
        gold.mask = mask
        gold.zPosition = zPosition
        self.dialView.layer.addSublayer(gold)
        self.goldLayers.append(gold)
    }

    private func buildDial(side: CGFloat) {
        let center = CGPoint(x: side * 0.5, y: side * 0.5)
        let root = self.dialView.layer
        let full = CGRect(x: 0.0, y: 0.0, width: side, height: side)

        self.plateLayer.frame = full
        self.plateLayer.path = UIBezierPath(arcCenter: center, radius: self.radius - 9.0, startAngle: 0.0, endAngle: .pi * 2.0, clockwise: true).cgPath
        self.plateLayer.fillColor = UIColor(red: 0.02, green: 0.03, blue: 0.1, alpha: 0.46).cgColor
        self.plateLayer.zPosition = 0.0
        root.addSublayer(self.plateLayer)

        self.addGoldRing(radius: self.radius + 27.0, lineWidth: 3.0, zPosition: 46.0, center: center, side: side)
        self.addGoldRing(radius: self.radius + 19.0, lineWidth: 0.8, zPosition: 40.0, center: center, side: side)
        self.addGoldRing(radius: self.radius - 9.0, lineWidth: 1.6, zPosition: 26.0, center: center, side: side)
        self.addGoldRing(radius: self.radius - 60.0, lineWidth: 0.8, zPosition: 12.0, center: center, side: side)

        let beads = UIBezierPath()
        let beadRadius = self.radius + 23.0
        for i in 0 ..< 96 {
            let angle = CGFloat(i) / 96.0 * .pi * 2.0
            let size: CGFloat = i % 8 == 0 ? 3.0 : 1.5
            beads.append(UIBezierPath(ovalIn: CGRect(x: center.x + beadRadius * sin(angle) - size * 0.5, y: center.y - beadRadius * cos(angle) - size * 0.5, width: size, height: size)))
        }
        self.beadsLayer.frame = full
        self.beadsLayer.path = beads.cgPath
        self.beadsLayer.fillColor = UIColor(white: 1.0, alpha: 0.78).cgColor
        self.beadsLayer.zPosition = 42.0
        root.addSublayer(self.beadsLayer)

        let minor = UIBezierPath()
        for i in 0 ..< 144 {
            let angle = CGFloat(i) / 144.0 * .pi * 2.0
            let outer = self.radius - 13.0
            let inner = outer - (i % 12 == 0 ? 11.0 : (i % 6 == 0 ? 7.0 : 4.0))
            minor.move(to: CGPoint(x: center.x + outer * sin(angle), y: center.y - outer * cos(angle)))
            minor.addLine(to: CGPoint(x: center.x + inner * sin(angle), y: center.y - inner * cos(angle)))
        }
        self.minorTicksLayer.frame = full
        self.minorTicksLayer.path = minor.cgPath
        self.minorTicksLayer.strokeColor = UIColor(white: 1.0, alpha: 0.72).cgColor
        self.minorTicksLayer.lineWidth = 1.0
        self.minorTicksLayer.lineCap = .round
        self.minorTicksLayer.zPosition = 20.0
        root.addSublayer(self.minorTicksLayer)

        for (index, text) in RemindDialView.romans.enumerated() {
            let angle = CGFloat(index) / 12.0 * .pi * 2.0
            let label = UILabel()
            label.text = text
            label.font = designedFont(index % 3 == 0 ? 15.0 : 12.0, .semibold, .serif)
            label.textColor = UIColor(white: 1.0, alpha: index % 3 == 0 ? 1.0 : 0.82)
            label.sizeToFit()
            let distance = self.radius - 38.0
            label.center = CGPoint(x: center.x + distance * sin(angle), y: center.y - distance * cos(angle))
            label.layer.zPosition = 24.0
            self.dialView.addSubview(label)
            self.numeralLabels.append(label)
        }

        self.arcMask.frame = full
        self.arcMask.fillColor = nil
        self.arcMask.strokeColor = UIColor.white.cgColor
        self.arcMask.lineWidth = 5.0
        self.arcMask.lineCap = .round
        self.arcContainer.frame = full
        self.arcContainer.type = .conic
        self.arcContainer.startPoint = CGPoint(x: 0.5, y: 0.5)
        self.arcContainer.endPoint = CGPoint(x: 0.5, y: 0.0)
        self.arcContainer.mask = self.arcMask
        self.arcContainer.zPosition = RemindDialView.trackDepth
        root.addSublayer(self.arcContainer)
        self.addGoldRing(radius: self.radius, lineWidth: 0.8, zPosition: 30.0, center: center, side: side)

        let nowAngle = self.nowMinute.truncatingRemainder(dividingBy: 720.0) / 720.0 * .pi * 2.0
        let nowDistance = self.radius + 11.0
        let nowPoint = CGPoint(x: center.x + nowDistance * sin(nowAngle), y: center.y - nowDistance * cos(nowAngle))
        let triangle = UIBezierPath()
        let along = CGPoint(x: sin(nowAngle), y: -cos(nowAngle))
        let across = CGPoint(x: cos(nowAngle), y: sin(nowAngle))
        triangle.move(to: CGPoint(x: nowPoint.x - along.x * 5.0, y: nowPoint.y - along.y * 5.0))
        triangle.addLine(to: CGPoint(x: nowPoint.x + along.x * 3.0 + across.x * 4.0, y: nowPoint.y + along.y * 3.0 + across.y * 4.0))
        triangle.addLine(to: CGPoint(x: nowPoint.x + along.x * 3.0 - across.x * 4.0, y: nowPoint.y + along.y * 3.0 - across.y * 4.0))
        triangle.close()
        self.nowLayer.frame = full
        self.nowLayer.path = triangle.cgPath
        self.nowLayer.fillColor = UIColor.white.cgColor
        self.nowLayer.zPosition = RemindDialView.trackDepth
        root.addSublayer(self.nowLayer)

        self.collarLayer.bounds = CGRect(x: 0.0, y: 0.0, width: 58.0, height: 58.0)
        self.collarLayer.path = UIBezierPath(ovalIn: CGRect(x: 1.0, y: 1.0, width: 56.0, height: 56.0)).cgPath
        self.collarLayer.fillColor = nil
        self.collarLayer.strokeColor = UIColor(white: 1.0, alpha: 0.85).cgColor
        self.collarLayer.lineWidth = 1.2
        self.collarLayer.zPosition = RemindDialView.trackDepth
        root.addSublayer(self.collarLayer)

        self.knobHole.frame = full
        self.knobHole.fillRule = .evenOdd
        self.knobHole.fillColor = UIColor.white.cgColor
        root.mask = self.knobHole

        self.dayLabel.textAlignment = .center
        self.dayLabel.frame = CGRect(x: center.x - 76.0, y: center.y - 50.0, width: 152.0, height: 18.0)
        self.dayLabel.layer.zPosition = 16.0
        self.dialView.addSubview(self.dayLabel)

        self.timeLabel.font = designedFont(37.0, .medium, .serif)
        self.timeLabel.textColor = .white
        self.timeLabel.textAlignment = .center
        self.timeLabel.adjustsFontSizeToFitWidth = true
        self.timeLabel.minimumScaleFactor = 0.6
        self.timeLabel.frame = CGRect(x: center.x - 72.0, y: center.y - 30.0, width: 144.0, height: 50.0)
        self.timeLabel.layer.zPosition = 18.0
        self.dialView.addSubview(self.timeLabel)

        self.relativeLabel.font = UIFont.systemFont(ofSize: 13.0, weight: .regular)
        self.relativeLabel.textColor = UIColor(white: 1.0, alpha: 0.78)
        self.relativeLabel.textAlignment = .center
        self.relativeLabel.frame = CGRect(x: center.x - 76.0, y: center.y + 22.0, width: 152.0, height: 18.0)
        self.relativeLabel.layer.zPosition = 16.0
        self.dialView.addSubview(self.relativeLabel)
    }

    private func buildChips(width: CGFloat) {
        var items: [(String, Int)] = [("In 1 hour", Int(ceil((self.nowMinute + 60.0) / 5.0) * 5.0))]
        if self.nowMinute + 30.0 < 20.0 * 60.0 {
            items.append(("Tonight", 20 * 60))
        }
        items.append(("Tomorrow", 1440 + 9 * 60))
        items.append(("Next week", 7 * 1440 + 9 * 60))

        let font = UIFont.systemFont(ofSize: 14.0, weight: .semibold)
        var x: CGFloat = 16.0
        var y: CGFloat = 2.0
        func addChip(title: String, tag: Int, icon: String?) -> UIButton {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = font
            button.setTitleColor(.white, for: .normal)
            button.tintColor = .white
            var chipWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width) + 24.0
            if let icon {
                button.setImage(UIImage(systemName: icon, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13.0, weight: .semibold)), for: .normal)
                button.setTitle(" \(title)", for: .normal)
                chipWidth += 22.0
            }
            button.backgroundColor = UIColor(white: 0.0, alpha: 0.3)
            button.layer.cornerRadius = 19.0
            button.layer.borderWidth = 1.0
            button.layer.borderColor = UIColor(white: 1.0, alpha: 0.28).cgColor
            button.frame = CGRect(x: x, y: y, width: chipWidth, height: 38.0)
            button.tag = tag
            self.chipsScroll.addSubview(button)
            x += chipWidth + 8.0
            return button
        }
        for item in items {
            let button = addChip(title: item.0, tag: item.1, icon: nil)
            button.addTarget(self, action: #selector(self.chipPressed(_:)), for: .touchUpInside)
            self.chips.append((button, item.1))
        }
        let confirmTop = self.bounds.height - max(self.safeInsets.bottom, 16.0) - 66.0
        let hasSecondRow = confirmTop - self.chipsScroll.frame.maxY >= 52.0
        var contentWidth = x - 8.0 + 16.0
        if hasSecondRow {
            let title = "Pick date & time"
            x = floor((width - (ceil((title as NSString).size(withAttributes: [.font: font]).width) + 46.0)) * 0.5)
            y = 48.0
            self.chipsScroll.frame.size.height = 88.0
            let custom = addChip(title: title, tag: 0, icon: "calendar")
            custom.addTarget(self, action: #selector(self.customPressed), for: .touchUpInside)
        } else {
            let custom = addChip(title: "Custom", tag: 0, icon: "calendar")
            custom.addTarget(self, action: #selector(self.customPressed), for: .touchUpInside)
            contentWidth = x - 8.0 + 16.0
        }
        self.chipsScroll.contentSize = CGSize(width: contentWidth, height: self.chipsScroll.bounds.height)
        if contentWidth < width {
            self.chipsScroll.contentInset.left = (width - contentWidth) * 0.5
        }
    }

    private func buildPickerPanel(width: CGFloat, height: CGFloat) {
        let panelHeight: CGFloat = 318.0 + self.safeInsets.bottom
        self.pickerPanel.frame = CGRect(x: 0.0, y: height, width: width, height: panelHeight)
        self.pickerPanel.layer.cornerRadius = 30.0
        self.pickerPanel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        self.pickerPanel.clipsToBounds = true

        let title = UILabel(frame: CGRect(x: 24.0, y: 18.0, width: width - 120.0, height: 28.0))
        title.text = "Pick a date and time"
        title.font = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
        title.textColor = .white
        self.pickerPanel.contentView.addSubview(title)

        let done = UIButton(type: .system)
        done.setTitle("Done", for: .normal)
        done.titleLabel?.font = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
        done.tintColor = .white
        done.frame = CGRect(x: width - 84.0, y: 14.0, width: 64.0, height: 36.0)
        done.addTarget(self, action: #selector(self.pickerDonePressed), for: .touchUpInside)
        self.pickerPanel.contentView.addSubview(done)

        self.datePicker.overrideUserInterfaceStyle = .dark
        self.datePicker.datePickerMode = .dateAndTime
        self.datePicker.preferredDatePickerStyle = .wheels
        self.datePicker.minuteInterval = 1
        self.datePicker.minimumDate = Date().addingTimeInterval(120.0)
        self.datePicker.maximumDate = Date().addingTimeInterval(365.0 * 86400.0)
        self.datePicker.frame = CGRect(x: 12.0, y: 56.0, width: width - 24.0, height: 240.0)
        self.datePicker.addTarget(self, action: #selector(self.pickerChanged), for: .valueChanged)
        self.pickerPanel.contentView.addSubview(self.datePicker)
        self.addSubview(self.pickerPanel)
    }

    private func date(for stepped: Int) -> Date {
        return self.startOfToday.addingTimeInterval(Double(stepped) * 60.0)
    }

    private func dayText(for date: Date, hour: CGFloat) -> String {
        let days = self.calendar.dateComponents([.day], from: self.startOfToday, to: self.calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0:
            return hour >= 18.0 ? "Tonight" : "Today"
        case 1:
            return "Tomorrow"
        case 2 ..< 7:
            return self.weekdayFormatter.string(from: date)
        default:
            return self.dateFormatter.string(from: date)
        }
    }

    private func isNearDay(_ day: String) -> Bool {
        return day == "Today" || day == "Tonight" || day == "Tomorrow"
    }

    private func applyMinute(haptics: Bool) {
        let stepped = self.exactMinute ?? Int((self.minute / 5.0).rounded()) * 5
        if stepped != self.steppedMinute {
            let previous = self.steppedMinute
            self.steppedMinute = stepped
            self.updateLabels(stepped: stepped)
            if haptics, previous >= 0 {
                if stepped % 60 == 0 {
                    self.hourFeedback.impactOccurred()
                } else {
                    self.tickFeedback.selectionChanged()
                }
            }
        }
    }

    private func updateLabels(stepped: Int) {
        let target = self.date(for: stepped)
        let hour = CGFloat(stepped % 1440) / 60.0
        let day = self.dayText(for: target, hour: hour)
        let time = self.timeFormatter.string(from: target)

        self.dayLabel.attributedText = NSAttributedString(string: day.uppercased(), attributes: [.kern: 2.2, .font: UIFont.systemFont(ofSize: 11.0, weight: .bold), .foregroundColor: UIColor(white: 1.0, alpha: 0.9)])
        self.timeLabel.text = time

        let total = max(CGFloat(stepped) - CGFloat(Date().timeIntervalSince(self.startOfToday) / 60.0), 1.0)
        let minutes = Int(total.rounded())
        if minutes < 60 {
            self.relativeLabel.text = "in \(minutes) min"
        } else if minutes < 1440 {
            let rest = minutes % 60
            self.relativeLabel.text = rest == 0 ? "in \(minutes / 60) h" : "in \(minutes / 60) h \(rest) min"
        } else {
            let days = Int((total / 1440.0).rounded())
            self.relativeLabel.text = days == 1 ? "in 1 day" : "in \(days) days"
        }

        UIView.performWithoutAnimation {
            self.confirmButton.setTitle("Remind me \(self.isNearDay(day) ? day.lowercased() : "on \(day)") at \(time)", for: .normal)
            self.confirmButton.layoutIfNeeded()
        }
        for chip in self.chips {
            chip.button.backgroundColor = chip.minute == stepped ? UIColor(white: 1.0, alpha: 0.34) : UIColor(white: 0.0, alpha: 0.3)
        }
    }

    public func present() {
        RemindSkyRenderer.load { [weak self] renderer in
            guard let self else {
                return
            }
            self.renderer = renderer
            self.skyLayer.device = renderer.device
            self.startLink()
            self.animateIn()
        }
    }

    private func startLink() {
        guard self.link == nil else {
            return
        }
        let link = CADisplayLink(target: RemindDisplayLinkTarget { [weak self] in
            self?.tick()
        }, selector: #selector(RemindDisplayLinkTarget.fire))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60.0, maximum: 60.0, preferred: 60.0)
        link.add(to: .main, forMode: .common)
        self.link = link
        self.lastTick = CACurrentMediaTime()
    }

    private func animateIn() {
        let width = self.bounds.width
        self.tick()
        UIView.animate(withDuration: 0.34) {
            self.alpha = 1.0
        }
        if self.snapshot != nil {
            let source = self.snapshotFrame
            let scale = min(1.0, min(112.0 / max(source.height, 1.0), (width - 40.0) / max(source.width, 1.0)))
            let size = CGSize(width: source.width * scale, height: source.height * scale)
            let target = CGRect(x: (width - size.width) * 0.5, y: self.safeInsets.top + 52.0, width: size.width, height: size.height)
            UIView.animate(withDuration: 0.55, delay: 0.0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.0, options: [], animations: {
                self.messageView.frame = target
            })
        }
        self.dialView.transform = CGAffineTransform(scaleX: 0.74, y: 0.74)
        UIView.animate(withDuration: 0.6, delay: 0.05, usingSpringWithDamping: 0.72, initialSpringVelocity: 0.0, options: [], animations: {
            self.dialView.transform = .identity
        })
        self.tickFeedback.prepare()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - self.lastTick, 1.0 / 20.0)
        self.lastTick = now
        self.clock += dt

        if let to = self.shortcutTo {
            let t = min((now - self.shortcutStart) / 0.7, 1.0)
            let eased = CGFloat(t * t * t * (t * (6.0 * t - 15.0) + 10.0))
            self.minute = self.shortcutFrom + (to - self.shortcutFrom) * eased
            if t >= 1.0 {
                self.shortcutTo = nil
                self.minute = to
            }
            self.applyMinute(haptics: false)
        }

        let change = self.minute - self.previousMinute
        self.previousMinute = self.minute
        self.spin += change / 720.0
        let instant = min(abs(change) / 720.0 / CGFloat(max(dt, 0.001)) * 0.9, 1.0)
        self.speed += (instant - self.speed) * min(CGFloat(dt) * (instant > self.speed ? 18.0 : 3.5), 1.0)

        self.layoutDial()
        self.renderSky()
    }

    private func layoutDial() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let center = CGPoint(x: self.dialView.bounds.midX, y: self.dialView.bounds.midY)
        let turned = self.minute.truncatingRemainder(dividingBy: 720.0) / 720.0
        let angle = turned * .pi * 2.0
        self.collarLayer.position = CGPoint(x: center.x + self.radius * sin(angle), y: center.y - self.radius * cos(angle))

        let start = self.nowMinute.truncatingRemainder(dividingBy: 720.0) / 720.0 * .pi * 2.0 - .pi * 0.5
        let sweep = min((self.minute - self.nowMinute) / 720.0 * .pi * 2.0, .pi * 2.0)
        self.arcMask.path = UIBezierPath(arcCenter: center, radius: self.radius, startAngle: start, endAngle: start + max(sweep, 0.001), clockwise: true).cgPath

        let hour = self.minute.truncatingRemainder(dividingBy: 1440.0) / 60.0
        let elevation = -cos(hour / 24.0 * .pi * 2.0)
        let day = max(min((elevation + 0.1) / 0.42, 1.0), 0.0)
        let bright = (1.0, 0.93, 0.68) as (CGFloat, CGFloat, CGFloat)
        let brightNight = (0.86, 0.92, 1.0) as (CGFloat, CGFloat, CGFloat)
        let deep = (0.72, 0.5, 0.18) as (CGFloat, CGFloat, CGFloat)
        let deepNight = (0.42, 0.5, 0.72) as (CGFloat, CGFloat, CGFloat)
        let highlight = mixColor(brightNight, bright, day)
        let shade = mixColor(deepNight, deep, day)
        let direction = CGPoint(x: 0.5 + 0.5 * sin(angle), y: 0.5 - 0.5 * cos(angle))
        for gold in self.goldLayers {
            gold.colors = [highlight, shade, highlight, shade, highlight]
            gold.locations = [0.0, 0.25, 0.5, 0.75, 1.0]
            gold.endPoint = direction
        }
        self.arcContainer.colors = [highlight, UIColor.white.cgColor, highlight]
        self.arcContainer.endPoint = direction

        self.beadsLayer.setAffineTransform(CGAffineTransform(rotationAngle: -self.spin * .pi * 2.0 * 0.35))

        let strength: CGFloat = self.isDragging ? 0.17 : 0.09
        let targetX = cos(angle) * strength + 0.012 * sin(CGFloat(self.clock) * 0.7)
        let targetY = sin(angle) * strength + 0.012 * cos(CGFloat(self.clock) * 0.55)
        self.tilt.x += (targetX - self.tilt.x) * 0.14
        self.tilt.y += (targetY - self.tilt.y) * 0.14
        var transform = CATransform3DIdentity
        transform.m34 = -1.0 / 620.0
        transform = CATransform3DRotate(transform, self.tilt.x, 1.0, 0.0, 0.0)
        transform = CATransform3DRotate(transform, self.tilt.y, 0.0, 1.0, 0.0)
        self.dialView.layer.sublayerTransform = transform

        let localX = self.radius * sin(angle)
        let localY = -self.radius * cos(angle)
        let depth = RemindDialView.trackDepth
        let w = localX * transform.m14 + localY * transform.m24 + depth * transform.m34 + transform.m44
        let projected = CGPoint(
            x: (localX * transform.m11 + localY * transform.m21 + depth * transform.m31 + transform.m41) / w,
            y: (localX * transform.m12 + localY * transform.m22 + depth * transform.m32 + transform.m42) / w
        )
        let appear = self.dialView.layer.presentation()?.affineTransform().a ?? 1.0
        self.knobPoint = CGPoint(x: self.dialCenter.x + projected.x * appear, y: self.dialCenter.y + projected.y * appear)
        self.knobScale = appear / w

        let hole = UIBezierPath(rect: self.dialView.bounds.insetBy(dx: -80.0, dy: -80.0))
        let holeRadius = 25.5 / w
        hole.append(UIBezierPath(ovalIn: CGRect(x: center.x + projected.x - holeRadius, y: center.y + projected.y - holeRadius, width: holeRadius * 2.0, height: holeRadius * 2.0)))
        self.knobHole.path = hole.cgPath

        CATransaction.commit()
    }

    private func renderSky() {
        guard let renderer = self.renderer else {
            return
        }
        let scale = self.skyLayer.contentsScale
        let knob = self.knobPoint
        let width = self.bounds.width
        let uniforms = RemindSkyUniforms(
            resolution: SIMD2(Float(width * scale), Float(self.bounds.height * scale)),
            center: SIMD2(Float(self.dialCenter.x * scale), Float(self.dialCenter.y * scale)),
            knob: SIMD2(Float(knob.x * scale), Float(knob.y * scale)),
            time: Float(self.clock.truncatingRemainder(dividingBy: 3000.0)),
            hour: Float(self.minute.truncatingRemainder(dividingBy: 1440.0) / 60.0),
            spin: Float(self.spin),
            speed: Float(self.speed),
            knobRadius: Float(25.0 * self.knobScale / width * 2.0)
        )
        renderer.draw(layer: self.skyLayer, uniforms: uniforms)
    }

    private func isInRing(_ point: CGPoint) -> Bool {
        let distance = hypot(point.x - self.dialCenter.x, point.y - self.dialCenter.y)
        return distance > self.radius - 62.0 && distance < self.radius + 54.0
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        return !(touch.view is UIControl)
    }

    override public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return !self.isClosing && !self.isPickerOpen && self.isInRing(gestureRecognizer.location(in: self))
    }

    private func angle(of point: CGPoint) -> CGFloat {
        return atan2(point.x - self.dialCenter.x, -(point.y - self.dialCenter.y))
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            self.shortcutTo = nil
            self.exactMinute = nil
            self.isDragging = true
            self.lastAngle = self.angle(of: point)
        case .changed:
            let current = self.angle(of: point)
            var delta = current - self.lastAngle
            if delta > .pi {
                delta -= .pi * 2.0
            } else if delta < -.pi {
                delta += .pi * 2.0
            }
            self.lastAngle = current
            self.minute = min(max(self.minute + delta / (.pi * 2.0) * 720.0, self.minimumMinute), self.maximumMinute)
            self.applyMinute(haptics: true)
        case .ended, .cancelled:
            self.isDragging = false
            self.minute = min(max(CGFloat(self.steppedMinute), self.minimumMinute), self.maximumMinute)
        default:
            break
        }
    }

    @objc private func chipPressed(_ sender: UIButton) {
        self.exactMinute = nil
        self.shortcutFrom = self.minute
        self.shortcutTo = min(max(CGFloat(sender.tag), self.minimumMinute), self.maximumMinute)
        self.shortcutStart = CACurrentMediaTime()
        self.hourFeedback.impactOccurred()
    }

    @objc private func customPressed() {
        self.datePicker.minimumDate = Date().addingTimeInterval(120.0)
        self.datePicker.setDate(max(self.date(for: self.steppedMinute), self.datePicker.minimumDate ?? Date()), animated: false)
        self.isPickerOpen = true
        UIView.animate(withDuration: 0.42, delay: 0.0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.0, options: [], animations: {
            self.pickerPanel.frame.origin.y = self.bounds.height - self.pickerPanel.bounds.height
            self.chipsScroll.alpha = 0.0
            self.confirmButton.alpha = 0.0
        })
    }

    @objc private func pickerChanged() {
        let value = Int(floor(self.datePicker.date.timeIntervalSince(self.startOfToday) / 60.0))
        self.shortcutTo = nil
        self.exactMinute = value
        self.minute = CGFloat(value)
        self.applyMinute(haptics: true)
    }

    @objc private func pickerDonePressed() {
        self.isPickerOpen = false
        UIView.animate(withDuration: 0.34, delay: 0.0, options: [.curveEaseInOut], animations: {
            self.pickerPanel.frame.origin.y = self.bounds.height
            self.chipsScroll.alpha = 1.0
            self.confirmButton.alpha = 1.0
        })
    }

    @objc private func closePressed() {
        guard !self.isClosing else {
            return
        }
        self.isClosing = true
        UIView.animate(withDuration: 0.28, delay: 0.0, options: [], animations: {
            self.alpha = 0.0
            self.messageView.frame = self.snapshotFrame
            self.dialView.transform = CGAffineTransform(scaleX: 0.84, y: 0.84)
        }, completion: { [weak self] _ in
            self?.link?.invalidate()
            self?.link = nil
            self?.onFinished?()
        })
    }

    @objc private func confirmDown() {
        UIView.animate(withDuration: 0.12) {
            self.confirmButton.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
        }
    }

    @objc private func confirmUp() {
        UIView.animate(withDuration: 0.18) {
            self.confirmButton.transform = .identity
        }
    }

    @objc private func confirmPressed() {
        guard !self.isClosing else {
            return
        }
        self.isClosing = true
        self.shortcutTo = nil
        self.commitFeedback.impactOccurred()

        let target = max(self.date(for: self.steppedMinute), Date().addingTimeInterval(90.0))
        let day = self.dayText(for: target, hour: CGFloat(self.calendar.component(.hour, from: target)))
        let description = "\(self.isNearDay(day) ? day.lowercased() : day) at \(self.timeFormatter.string(from: target))"

        UIView.animate(withDuration: 0.22) {
            self.headingLabel.alpha = 0.0
            self.closeButton.alpha = 0.0
            self.clockView.alpha = 1.0
            self.chipsScroll.alpha = 0.0
            self.confirmButton.alpha = 0.0
        }
        UIView.animate(withDuration: 0.34) {
            self.dialView.alpha = 0.0
            self.dialView.transform = CGAffineTransform(scaleX: 0.86, y: 0.86)
        }

        let note = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 40.0, height: 30.0))
        note.backgroundColor = UIColor(red: 1.0, green: 0.82, blue: 0.4, alpha: 1.0)
        note.layer.cornerRadius = 7.0
        note.layer.shadowColor = UIColor(red: 1.0, green: 0.74, blue: 0.2, alpha: 1.0).cgColor
        note.layer.shadowRadius = 16.0
        note.layer.shadowOpacity = 0.95
        note.layer.shadowOffset = .zero
        note.alpha = 0.0
        self.addSubview(note)

        let finish: (CGPoint) -> Void = { [weak self, weak note] start in
            guard let self, let note else {
                return
            }
            self.fly(note: note, from: start, date: target, description: description)
        }

        guard let snapshot = self.snapshot else {
            let start = self.dialCenter
            note.center = start
            note.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
            UIView.animate(withDuration: 0.22, animations: {
                note.alpha = 1.0
                note.transform = .identity
            }, completion: { _ in
                finish(start)
            })
            return
        }

        let frame = self.messageView.frame
        let host = UIView(frame: frame)
        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / 500.0
        host.layer.sublayerTransform = perspective
        self.addSubview(host)
        self.bringSubviewToFront(note)
        self.messageView.isHidden = true

        let top = CALayer()
        top.contents = snapshot
        top.contentsRect = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 0.5)
        top.frame = CGRect(x: 0.0, y: 0.0, width: frame.width, height: frame.height * 0.5)
        host.layer.addSublayer(top)

        let bottom = CALayer()
        bottom.contents = snapshot
        bottom.contentsRect = CGRect(x: 0.0, y: 0.5, width: 1.0, height: 0.5)
        bottom.anchorPoint = CGPoint(x: 0.5, y: 0.0)
        bottom.bounds = CGRect(x: 0.0, y: 0.0, width: frame.width, height: frame.height * 0.5)
        bottom.position = CGPoint(x: frame.width * 0.5, y: frame.height * 0.5)
        bottom.zPosition = 1.0
        host.layer.addSublayer(bottom)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak host, weak note] in
            guard let host, let note else {
                return
            }
            let center = CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.25)
            note.center = center
            note.transform = CGAffineTransform(scaleX: max(frame.width / 40.0, 1.0), y: max(frame.height * 0.5 / 30.0, 0.8))
            UIView.animate(withDuration: 0.24, delay: 0.0, options: [.curveEaseInOut], animations: {
                note.alpha = 1.0
                note.transform = .identity
                host.alpha = 0.0
                host.transform = CGAffineTransform(scaleX: 40.0 / max(frame.width, 40.0), y: 0.2)
            }, completion: { _ in
                host.removeFromSuperview()
                finish(center)
            })
        }
        let fold = CABasicAnimation(keyPath: "transform.rotation.x")
        fold.fromValue = 0.0
        fold.toValue = CGFloat.pi * 0.98
        fold.duration = 0.3
        fold.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fold.fillMode = .forwards
        fold.isRemovedOnCompletion = false
        bottom.add(fold, forKey: "fold")
        CATransaction.commit()
    }

    private func fly(note: UIView, from start: CGPoint, date: Date, description: String) {
        let end = self.clockView.center
        let path = UIBezierPath()
        path.move(to: start)
        path.addQuadCurve(to: end, controlPoint: CGPoint(x: start.x + (end.x - start.x) * 0.2 + 70.0, y: min(start.y, end.y) + 8.0))

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak note] in
            note?.removeFromSuperview()
            guard let self else {
                return
            }
            self.hourFeedback.impactOccurred()
            self.onCommit?(date, description)
            UIView.animate(withDuration: 0.16, animations: {
                self.clockView.transform = CGAffineTransform(scaleX: 1.28, y: 1.28)
            }, completion: { _ in
                UIView.animate(withDuration: 0.34, delay: 0.0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0.0, options: [], animations: {
                    self.clockView.transform = .identity
                }, completion: { _ in
                    UIView.animate(withDuration: 0.3, animations: {
                        self.alpha = 0.0
                    }, completion: { _ in
                        self.link?.invalidate()
                        self.link = nil
                        self.onFinished?()
                    })
                })
            })
        }
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path.cgPath
        move.duration = 0.5
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        move.fillMode = .forwards
        move.isRemovedOnCompletion = false
        note.layer.add(move, forKey: "fly")

        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1.0
        shrink.toValue = 0.4
        shrink.duration = 0.5
        shrink.fillMode = .forwards
        shrink.isRemovedOnCompletion = false
        note.layer.add(shrink, forKey: "shrink")
        CATransaction.commit()
    }
}
