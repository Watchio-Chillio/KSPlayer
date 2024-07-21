import AVFoundation
import Foundation
import Libavcodec
import Libavformat
import KSPlayer

public class KSPlayerMediaThumbnailer {
  private init() {}
  
  public static func generateThumbnail(for url: URL, at time: TimeInterval, thumbWidth: Int32 = 240) async throws -> FFThumbnail? {
    return try await Task {
      try getPeek(for: url, at: time, thumbWidth: thumbWidth)
    }.value
  }
  
  private static func getPeek(for url: URL, at time: TimeInterval, thumbWidth: Int32 = 240) throws -> FFThumbnail? {
    let urlString: String
    if url.isFileURL {
      urlString = url.path
    } else {
      urlString = url.absoluteString
    }
    var formatCtx = avformat_alloc_context()
    defer {
      avformat_close_input(&formatCtx)
    }
    var result = avformat_open_input(&formatCtx, urlString, nil, nil)
    guard result == 0, let formatCtx else {
      throw NSError(errorCode: .formatOpenInput, avErrorCode: result)
    }
    result = avformat_find_stream_info(formatCtx, nil)
    guard result == 0 else {
      throw NSError(errorCode: .formatFindStreamInfo, avErrorCode: result)
    }
    var videoStreamIndex = -1
    for i in 0 ..< Int32(formatCtx.pointee.nb_streams) {
      if formatCtx.pointee.streams[Int(i)]?.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
        videoStreamIndex = Int(i)
        break
      }
    }
    guard videoStreamIndex >= 0, let videoStream = formatCtx.pointee.streams[videoStreamIndex] else {
      throw NSError(description: "No video stream")
    }
    
    let videoAvgFrameRate = videoStream.pointee.avg_frame_rate
    if videoAvgFrameRate.den == 0 || av_q2d(videoAvgFrameRate) == 0 {
      throw NSError(description: "Avg frame rate = 0, ignore")
    }
    var codecContext = try videoStream.pointee.codecpar.pointee.createContext(options: nil)
    defer {
      avcodec_close(codecContext)
      var codecContext: UnsafeMutablePointer<AVCodecContext>? = codecContext
      avcodec_free_context(&codecContext)
    }
    let thumbHeight = thumbWidth * codecContext.pointee.height / codecContext.pointee.width
    let reScale = VideoSwresample(dstWidth: thumbWidth, dstHeight: thumbHeight, isDovi: false)
    let duration = av_rescale_q(formatCtx.pointee.duration,
                                AVRational(num: 1, den: AV_TIME_BASE), videoStream.pointee.time_base)
    let seek_pos = Int64(time * Double(videoStream.pointee.time_base.den) / Double(videoStream.pointee.time_base.num))
    var packet = AVPacket()
    let timeBase = Timebase(videoStream.pointee.time_base)
    var frame = av_frame_alloc()
    defer {
      av_frame_free(&frame)
    }
    guard let frame else {
      throw NSError(description: "can not av_frame_alloc")
    }
    
    avcodec_flush_buffers(codecContext)
    result = av_seek_frame(formatCtx, Int32(videoStreamIndex), seek_pos, AVSEEK_FLAG_BACKWARD)
    guard result == 0 else {
      throw NSError(description: "Failed to seek to position")
    }
    
    avcodec_flush_buffers(codecContext)
    while av_read_frame(formatCtx, &packet) >= 0 {
      if packet.stream_index == Int32(videoStreamIndex) {
        if avcodec_send_packet(codecContext, &packet) < 0 {
          break
        }
        let ret = avcodec_receive_frame(codecContext, frame)
        if ret < 0 {
          if ret == -EAGAIN {
            continue
          } else {
            break
          }
        }
        let image = reScale.transfer(frame: frame.pointee)?.cgImage().map {
          UIImage(cgImage: $0)
        }
        let currentTimeStamp = frame.pointee.best_effort_timestamp
        if let image {
          return FFThumbnail(image: image, time: timeBase.cmtime(for: currentTimeStamp).seconds)
        }
        break
      }
    }
    av_packet_unref(&packet)
    reScale.shutdown()
    return nil
  }
}
