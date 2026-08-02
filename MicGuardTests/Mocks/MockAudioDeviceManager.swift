//
//  MockAudioDeviceManager.swift
//  MicGuardTests
//
//  Mock implementation of AudioDeviceManaging for testing
//

import Foundation
import Combine
@testable import MicGuard

class MockAudioDeviceManager: AudioDeviceManaging {
    
    // MARK: - Publishers
    
    let devicesChangedPublisher = PassthroughSubject<Void, Never>()
    let defaultInputChangedPublisher = PassthroughSubject<AudioDevice?, Never>()
    let defaultOutputChangedPublisher = PassthroughSubject<AudioDevice?, Never>()
    let inputDeviceRunningChangedPublisher = PassthroughSubject<Void, Never>()
    
    // MARK: - Mock Data
    
    var inputDevices: [AudioDevice] = []
    var outputDevices: [AudioDevice] = []
    
    private var _defaultInputDevice: AudioDevice?
    private var _defaultOutputDevice: AudioDevice?
    
    var defaultInputDevice: AudioDevice? {
        return _defaultInputDevice
    }
    
    var defaultOutputDevice: AudioDevice? {
        return _defaultOutputDevice
    }
    
    // MARK: - Volume Storage
    
    private var deviceVolumes: [String: Float] = [:]
    private var deviceRunningState: [String: Bool] = [:]
    
    // MARK: - Call Tracking
    
    var setDefaultInputDeviceCalls: [AudioDevice] = []
    var setDefaultOutputDeviceCalls: [AudioDevice] = []
    var setInputVolumeCalls: [(volume: Float, device: AudioDevice)] = []
    
    // MARK: - Mock Control
    
    var shouldFailSetDevice = false
    var shouldFailSetVolume = false

    // UIDs for which setDefault* reports success but the default silently stays
    // put — mirrors macOS's behavior for virtual/aggregate devices.
    var silentlyRefusedUIDs: Set<String> = []
    
    // MARK: - Setup Helpers
    
    func setupMockDevices() {
        let internalMic = AudioDevice(
            id: 1,
            uid: "BuiltInMicrophone",
            name: "Internal Microphone",
            isInput: true,
            isOutput: false
        )
        
        let airpodsMic = AudioDevice(
            id: 2,
            uid: "AirPodsPro",
            name: "AirPods Pro",
            isInput: true,
            isOutput: true
        )
        
        let externalMic = AudioDevice(
            id: 3,
            uid: "ShureMV7",
            name: "Shure MV7",
            isInput: true,
            isOutput: false
        )
        
        let speakers = AudioDevice(
            id: 4,
            uid: "BuiltInSpeakers",
            name: "MacBook Pro Speakers",
            isInput: false,
            isOutput: true
        )
        
        let hdmiOutput = AudioDevice(
            id: 5,
            uid: "HDMIOutput",
            name: "LG Monitor",
            isInput: false,
            isOutput: true
        )
        
        inputDevices = [internalMic, airpodsMic, externalMic]
        outputDevices = [airpodsMic, speakers, hdmiOutput]
        
        _defaultInputDevice = internalMic
        _defaultOutputDevice = speakers
        
        // Set default volumes
        deviceVolumes[internalMic.uid] = 0.5
        deviceVolumes[externalMic.uid] = 0.75
        deviceVolumes[airpodsMic.uid] = 0.6
        
        // Set running state
        deviceRunningState[internalMic.uid] = false
        deviceRunningState[externalMic.uid] = false
        deviceRunningState[airpodsMic.uid] = false
    }
    
    // MARK: - AudioDeviceManaging Implementation
    
    func setDefaultInputDevice(_ device: AudioDevice) -> Bool {
        setDefaultInputDeviceCalls.append(device)

        guard !shouldFailSetDevice else { return false }
        guard !silentlyRefusedUIDs.contains(device.uid) else { return true }

        _defaultInputDevice = device
        defaultInputChangedPublisher.send(device)
        return true
    }
    
    func setDefaultOutputDevice(_ device: AudioDevice) -> Bool {
        setDefaultOutputDeviceCalls.append(device)

        guard !shouldFailSetDevice else { return false }
        guard !silentlyRefusedUIDs.contains(device.uid) else { return true }

        _defaultOutputDevice = device
        defaultOutputChangedPublisher.send(device)
        return true
    }
    
    func getInputVolume(for device: AudioDevice) -> Float? {
        return deviceVolumes[device.uid]
    }
    
    func setInputVolume(_ volume: Float, for device: AudioDevice) -> Bool {
        setInputVolumeCalls.append((volume: volume, device: device))

        guard !shouldFailSetVolume else { return false }

        deviceVolumes[device.uid] = volume
        return true
    }

    func getOutputVolume(for device: AudioDevice) -> Float? {
        return deviceVolumes[device.uid]
    }

    func setOutputVolume(_ volume: Float, for device: AudioDevice) -> Bool {
        guard !shouldFailSetVolume else { return false }
        deviceVolumes[device.uid] = volume
        return true
    }
    
    func isDeviceRunning(_ device: AudioDevice) -> Bool {
        return deviceRunningState[device.uid] ?? false
    }
    
    func device(forUID uid: String) -> AudioDevice? {
        return inputDevices.first { $0.uid == uid } ?? outputDevices.first { $0.uid == uid }
    }

    func inputDevices(withName name: String) -> [AudioDevice] {
        return inputDevices.filter { $0.name == name }
    }

    func outputDevices(withName name: String) -> [AudioDevice] {
        return outputDevices.filter { $0.name == name }
    }
    
    // MARK: - Simulation Helpers
    
    func simulateDeviceSwitch(to device: AudioDevice) {
        _defaultInputDevice = device
        defaultInputChangedPublisher.send(device)
    }
    
    func simulateOutputDeviceSwitch(to device: AudioDevice) {
        _defaultOutputDevice = device
        defaultOutputChangedPublisher.send(device)
    }
    
    func simulateVolumeChange(for device: AudioDevice, to volume: Float) {
        deviceVolumes[device.uid] = volume
    }
    
    func simulateDeviceRunning(_ device: AudioDevice, isRunning: Bool) {
        deviceRunningState[device.uid] = isRunning
    }
    
    func simulateDeviceDisconnected(_ device: AudioDevice) {
        inputDevices.removeAll { $0.uid == device.uid }
        outputDevices.removeAll { $0.uid == device.uid }
        devicesChangedPublisher.send()
    }
    
    func simulateDeviceReconnected(_ device: AudioDevice) {
        if device.isInput && !inputDevices.contains(device) {
            inputDevices.append(device)
        }
        if device.isOutput && !outputDevices.contains(device) {
            outputDevices.append(device)
        }
        devicesChangedPublisher.send()
    }
}
