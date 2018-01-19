import AudioToolbox

class Recorder {

    static let shared = Recorder()
    private static let sampleRate: Float64 = 16000

    var processAudioData: ((Data) -> ())?

    fileprivate var remoteIOUnit: AudioComponentInstance?
    private var audioFile: AudioFileID?
    private var startingByte: Int64 = 0
    // Audio recording settings
    private let formatId: AudioFormatID = kAudioFormatLinearPCM
    private let bitsPerChannel: UInt32 = 16
    private let channelsPerFrame: UInt32 = 1
    private let bytesPerFrame: UInt32 = 2 // channelsPerFrame * 2
    private let framesPerPacket: UInt32 = 1
    private let encoderBitRate = 12800
    private let formatFlags: AudioFormatFlags = kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked

    func record(atURL url: URL) {
        var status = openFileForWriting(fileURL: url)
        startingByte = 0
        status = prepareAudioToolbox()
        status = startAudioToolboxRecording()
    }

    func openFileForWriting(fileURL: URL) -> OSStatus {
        var asbd = AudioStreamBasicDescription()
        memset(&asbd, 0, MemoryLayout<AudioStreamBasicDescription>.size)
        asbd.mSampleRate = Recorder.sampleRate
        asbd.mFormatID = formatId
        asbd.mFormatFlags = formatFlags
        asbd.mBitsPerChannel = bitsPerChannel
        asbd.mChannelsPerFrame = channelsPerFrame
        asbd.mFramesPerPacket = framesPerPacket
        asbd.mBytesPerFrame = bytesPerFrame
        asbd.mBytesPerPacket = framesPerPacket * bytesPerFrame
        // Set up the file
        var audioFile: AudioFileID?
        var audioErr: OSStatus = noErr
        audioErr = AudioFileCreateWithURL(fileURL as CFURL, AudioFileTypeID(kAudioFileWAVEType), &asbd, .eraseFile, &audioFile)
        if audioErr == noErr {
            self.audioFile = audioFile
        }
        return audioErr
    }

    func prepareAudioToolbox() -> OSStatus {
        var status = noErr
        // Describe the RemoteIO unit
        var audioComponentDescription = AudioComponentDescription()
        audioComponentDescription.componentType = kAudioUnitType_Output
        audioComponentDescription.componentSubType = kAudioUnitSubType_RemoteIO
        audioComponentDescription.componentManufacturer = kAudioUnitManufacturer_Apple
        audioComponentDescription.componentFlags = 0
        audioComponentDescription.componentFlagsMask = 0
        // Get the RemoteIO unit
        var ioUnit: AudioComponentInstance?
        let remoteIOComponent = AudioComponentFindNext(nil, &audioComponentDescription)
        status = AudioComponentInstanceNew(remoteIOComponent!, &ioUnit)
        guard status == noErr else {
            return status
        }
        guard let remoteIOUnit = ioUnit else {
            return 656783
        }
        self.remoteIOUnit = remoteIOUnit
        // Configure the RemoteIO unit for input
        let bus1: AudioUnitElement = 1
        var oneFlag: UInt32 = 1
        status = AudioUnitSetProperty(remoteIOUnit,
                                      kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Input,
                                      bus1,
                                      &oneFlag,
                                      UInt32(MemoryLayout<UInt32>.size));
        guard status == noErr else {
            return status
        }
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = Recorder.sampleRate
        asbd.mFormatID = formatId
        asbd.mFormatFlags = formatFlags
        asbd.mBitsPerChannel = bitsPerChannel
        asbd.mChannelsPerFrame = channelsPerFrame
        asbd.mFramesPerPacket = framesPerPacket
        asbd.mBytesPerFrame = bytesPerFrame
        asbd.mBytesPerPacket = framesPerPacket * bytesPerFrame
        // Set format for mic input (bus 1) on RemoteIO's output scope
        status = AudioUnitSetProperty(remoteIOUnit,
                                      kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output,
                                      bus1,
                                      &asbd,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else {
            return status
        }
        // Set the recording callback
        var callbackStruct = AURenderCallbackStruct()
        callbackStruct.inputProc = recordingCallback
        callbackStruct.inputProcRefCon = nil
        status = AudioUnitSetProperty(remoteIOUnit,
                                      kAudioOutputUnitProperty_SetInputCallback,
                                      kAudioUnitScope_Global,
                                      bus1,
                                      &callbackStruct,
                                      UInt32(MemoryLayout<AURenderCallbackStruct>.size));
        guard status == noErr else {
            return status
        }
        // Initialize the RemoteIO unit
        return AudioUnitInitialize(remoteIOUnit)
    }

    func startAudioToolboxRecording() -> OSStatus {
        guard let remoteIOUnit = remoteIOUnit else {
            return 656783
        }
        return AudioOutputUnitStart(remoteIOUnit)
    }

    func writeDataToFile(audioBuffers: UnsafeMutableBufferPointer<AudioBuffer>) -> OSStatus {
        guard let audioFile = audioFile else {
            return 176136
        }
        var startingByte = self.startingByte
        for audioBuffer in audioBuffers {
            var numBytes = audioBuffer.mDataByteSize
            guard let mData = audioBuffer.mData else {
                continue
            }
            // [1] following call fails with `-38` error (`kAudioFileNotOpenError`). Less often it fails with `1868981823` error (`kAudioFileDoesNotAllow64BitDataSizeError`)
            let audioErr = AudioFileWriteBytes(audioFile,
                                               false,
                                               startingByte,
                                               &numBytes,
                                               mData)
            guard audioErr == noErr else {
                return audioErr
            }
            let data = Data(bytes:  mData, count: Int(numBytes))
            processAudioData?(data)
            startingByte += Int64(numBytes)
        }
        self.startingByte = startingByte
        return noErr
    }

}

private func recordingCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {

    guard let remoteIOUnit = Recorder.shared.remoteIOUnit else {
        return 656783
    }
    var status = noErr
    let channelCount: UInt32 = 1
    var bufferList = AudioBufferList()
    bufferList.mNumberBuffers = channelCount
    let buffers = UnsafeMutableBufferPointer<AudioBuffer>(start: &bufferList.mBuffers,
                                                          count: Int(bufferList.mNumberBuffers))
    buffers[0].mNumberChannels = 1
    buffers[0].mDataByteSize = inNumberFrames * 2
    buffers[0].mData = nil
    // get the recorded samples
    // [2] following call fails with `-10863` error (`kAudioUnitErr_CannotDoInCurrentContext`) and less often with `-1` error
    status = AudioUnitRender(remoteIOUnit,
                             ioActionFlags,
                             inTimeStamp,
                             inBusNumber,
                             inNumberFrames,
                             UnsafeMutablePointer<AudioBufferList>(&bufferList))
    guard status == noErr else {
        return status
    }
    status = Recorder.shared.writeDataToFile(audioBuffers: buffers)
    return status
}
