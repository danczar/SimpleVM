//
//  VirtualMachineViewModel.swift
//  SimpleVM
//
//  Created by Khaos Tian on 7/26/20.
//

import Cocoa
import Combine
import Virtualization

class VirtualMachineViewModel: NSObject, ObservableObject, VZVirtualMachineDelegate {
    
    private var virtualMachine: VZVirtualMachine?
    
    @Published var kernelURL: URL?
    @Published var initialRamdiskURL: URL?
    @Published var bootableImageURL: URL?
    @Published var persistentHarddiskURL: URL?
    
    @Published var state: VZVirtualMachine.State?
    
    private lazy var consoleWindow: NSWindow = {
        let viewController = ConsoleViewController()
        viewController.configure(with: readPipe, writePipe: writePipe)
        return NSWindow(contentViewController: viewController)
    }()
    
    private lazy var consoleWindowController: NSWindowController = {
        let windowController = NSWindowController(window: consoleWindow)
        return windowController
    }()
    
    private let readPipe = Pipe()
    private let writePipe = Pipe()
    private var cancellables: Set<AnyCancellable> = []
    
    var isReady: Bool {
        return kernelURL != nil && initialRamdiskURL != nil && bootableImageURL != nil
    }
    
    var stateDescription: String? {
        guard let state = state else {
            return nil
        }
        
        switch state {
        case .stopped:
            return "Stopped"
        case .running:
            return "Running"
        case .paused:
            return "Paused"
        case .error:
            return "Error"
        case .starting:
            return "Starting"
        case .pausing:
            return "Pausing"
        case .resuming:
            return "Resuming"
        @unknown default:
            return "Unknown \(state.rawValue)"
        }
    }
    
    func start() {
        guard let kernelURL = kernelURL,
              let initialRamdiskURL = initialRamdiskURL,
              let bootableImageURL = bootableImageURL,
              let persistentHarddiskURL = persistentHarddiskURL else {
            return
        }
        
        cancellables = []
        state = nil
        
        let bootloader = VZLinuxBootLoader(kernelURL: kernelURL)
        bootloader.initialRamdiskURL = initialRamdiskURL
        bootloader.commandLine = "console=hvc0"
        
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: writePipe.fileHandleForReading,
            fileHandleForWriting: readPipe.fileHandleForWriting
        )

        let entropy = VZVirtioEntropyDeviceConfiguration()
        
        let memoryBalloon = VZVirtioTraditionalMemoryBalloonDeviceConfiguration()
        
        let bootAttachment: VZDiskImageStorageDeviceAttachment
        
        do {
            bootAttachment = try VZDiskImageStorageDeviceAttachment(
                url: bootableImageURL,
                readOnly: true
            )
        } catch {
            NSLog("Failed to load bootable iso: \(error)")
            return
        }
        
        let blockAttachment: VZDiskImageStorageDeviceAttachment
        
        do {
            blockAttachment = try VZDiskImageStorageDeviceAttachment(
                url: persistentHarddiskURL,
                readOnly: false
            )
        } catch {
            NSLog("Failed to load virtual disk image: \(error)")
            return
        }
        
        let bootableDevice = VZVirtioBlockDeviceConfiguration(attachment: bootAttachment)
        let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: blockAttachment)
        
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        
        let config = VZVirtualMachineConfiguration()
        config.bootLoader = bootloader
        config.cpuCount = 8
        config.memorySize = 8 * 1024 * 1024 * 1024
        config.entropyDevices = [entropy]
        config.memoryBalloonDevices = [memoryBalloon]
        config.serialPorts = [serial]
        config.storageDevices = [blockDevice]
        config.networkDevices = [networkDevice]
                
        do {
            try config.validate()
            
            let vm = VZVirtualMachine(configuration: config)
            vm.delegate = self
            self.virtualMachine = vm
            
            KeyValueObservingPublisher(object: vm, keyPath: \.state, options: [.initial, .new])
                .sink { [weak self] state in
                    self?.state = state
                }
                .store(in: &cancellables)
            
            vm.start { result in
                switch result {
                case .success:
                    break
                case .failure(let error):
                    NSLog("Failed: \(error)")
                }
            }
        } catch {
            NSLog("Error: \(error)")
            return
        }
    }
    
    func stop() {
        cancellables = []
        state = nil
        if let virtualMachine = virtualMachine {
            do {
                try virtualMachine.requestStop()
            } catch {
                NSLog("Failed to stop: \(error)")
            }
            self.virtualMachine = nil
        }
    }
    
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        NSLog("Stopped")
    }
    
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        NSLog("Stopped with error: \(error)")
    }
    
    func showConsole() {
        consoleWindow.setContentSize(NSSize(width: 1024, height: 768))
        consoleWindow.title = "Console"
        consoleWindowController.showWindow(nil)
    }
}
