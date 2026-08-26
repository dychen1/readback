import Carbon

public enum GlobalHotKeyError: Error, Equatable, Sendable {
    case installHandler(OSStatus)
    case registerShortcut(OSStatus)
}

@MainActor
public final class GlobalHotKey {
    private var registration: CarbonHotKeyRegistration?

    public init() {}

    public func registerReadClipboard(
        action: @escaping @MainActor @Sendable () -> Void
    ) throws {
        let callback = CarbonHotKeyCallback(action: action)
        var handler: EventHandlerRef?

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                let callback = Unmanaged<CarbonHotKeyCallback>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                MainActor.assumeIsolated {
                    callback.action()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(callback).toOpaque(),
            &handler
        )
        guard handlerStatus == noErr else {
            throw GlobalHotKeyError.installHandler(handlerStatus)
        }

        let identifier = EventHotKeyID(signature: 0x5244424B, id: 1)
        var hotKey: EventHotKeyRef?
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            UInt32(cmdKey | optionKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard registrationStatus == noErr else {
            if let handler {
                RemoveEventHandler(handler)
            }
            throw GlobalHotKeyError.registerShortcut(registrationStatus)
        }
        registration = CarbonHotKeyRegistration(
            hotKey: hotKey,
            handler: handler,
            callback: callback
        )
    }
}

private final class CarbonHotKeyCallback: @unchecked Sendable {
    let action: @MainActor @Sendable () -> Void

    init(action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
    }
}

private final class CarbonHotKeyRegistration: @unchecked Sendable {
    private let hotKey: EventHotKeyRef?
    private let handler: EventHandlerRef?
    private let callback: CarbonHotKeyCallback

    init(
        hotKey: EventHotKeyRef?,
        handler: EventHandlerRef?,
        callback: CarbonHotKeyCallback
    ) {
        self.hotKey = hotKey
        self.handler = handler
        self.callback = callback
    }

    deinit {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let handler {
            RemoveEventHandler(handler)
        }
        _ = callback
    }
}
