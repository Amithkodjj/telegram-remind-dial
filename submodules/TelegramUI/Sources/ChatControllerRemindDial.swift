import Foundation
import UIKit
import Display
import TelegramCore
import SwiftSignalKit
import UndoUI
import ChatMessageItemView
import RemindDial

extension ChatControllerImpl {
    func presentRemindDial(messageIds: [EngineMessage.Id]) {
        self.chatDisplayNode.dismissInput()
        RemindDialView.prewarm()
        Queue.mainQueue().after(0.24) { [weak self] in
            guard let self else {
                return
            }
            let ids = Set(messageIds)
            let host: UIView = self.view
            var image: CGImage?
            var frame = CGRect(x: host.bounds.midX - 1.0, y: host.bounds.midY - 1.0, width: 2.0, height: 2.0)
            self.chatDisplayNode.historyNode.forEachVisibleItemNode { node in
                guard image == nil, let itemNode = node as? ChatMessageItemView, let item = itemNode.item, item.content.contains(where: { ids.contains($0.0.id) }) else {
                    return
                }
                guard let (snapshot, subFrame) = itemNode.makeContentSnapshot(), let cgImage = snapshot.cgImage else {
                    return
                }
                image = cgImage
                frame = itemNode.view.convert(subFrame, to: host)
            }

            let view = RemindDialView(frame: host.bounds, safeInsets: host.safeAreaInsets, snapshot: image, snapshotFrame: frame)
            view.disablesInteractiveTransitionGestureRecognizer = true
            host.addSubview(view)
            view.onCommit = { [weak self] date, description in
                self?.scheduleReminder(messageIds: messageIds, date: date, description: description)
            }
            let previousStatusBarStyle = self.statusBar.statusBarStyle
            self.isRemindDialVisible = true
            self.statusBar.updateStatusBarStyle(.White, animated: true)
            view.onFinished = { [weak self, weak view] in
                view?.removeFromSuperview()
                self?.isRemindDialVisible = false
                self?.statusBar.updateStatusBarStyle(previousStatusBarStyle, animated: true)
            }
            view.present()
        }
    }

    private func scheduleReminder(messageIds: [EngineMessage.Id], date: Date, description: String) {
        let context = self.context
        let scheduleTime = Int32(date.timeIntervalSince1970)
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.present(UndoOverlayController(
            presentationData: presentationData,
            content: .info(title: nil, text: "Reminder set for \(description)", timeout: 5.0, customUndoText: "Undo"),
            elevatedLayout: false,
            action: { action in
                if case .commit = action {
                    let messages: [EnqueueMessage] = messageIds.map { id in
                        return .forward(source: id, threadId: nil, grouping: .auto, attributes: [OutgoingScheduleInfoMessageAttribute(scheduleTime: scheduleTime, repeatPeriod: nil)], correlationId: nil)
                    }
                    let _ = enqueueMessages(account: context.account, peerId: context.account.peerId, messages: messages).startStandalone()
                }
                return false
            }
        ), in: .window(.root))
    }
}
