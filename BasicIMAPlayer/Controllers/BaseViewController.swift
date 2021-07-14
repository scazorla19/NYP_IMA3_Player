//
//  BaseViewController.swift
//  BasicIMAPlayer
//
//  Copyright © 2020 Brightcove, Inc. All rights reserved.
//

import UIKit
import BrightcovePlayerSDK
import BrightcoveIMA
import GoogleInteractiveMediaAds
import AppTrackingTransparency


class BaseViewController: UIViewController {

    @IBOutlet weak var videoContainerView: UIView!
    
    lazy var playerView: BCOVPUIPlayerView? = {
        let options = BCOVPUIPlayerViewOptions()
        options.presentingViewController = self
        
        // Create PlayerUI views with normal VOD controls.
        let controlView = BCOVPUIBasicControlView.withVODLayout()
        guard let _playerView = BCOVPUIPlayerView(playbackController: nil, options: options, controlsView: controlView) else {
            return nil
        }

        // Add to parent view
        self.videoContainerView.addSubview(_playerView)
        _playerView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            _playerView.topAnchor.constraint(equalTo: self.videoContainerView.topAnchor),
            _playerView.rightAnchor.constraint(equalTo: self.videoContainerView.rightAnchor),
            _playerView.leftAnchor.constraint(equalTo: self.videoContainerView.leftAnchor),
            _playerView.bottomAnchor.constraint(equalTo: self.videoContainerView.bottomAnchor)
        ])
        
        return _playerView
    }()
    
    var playbackController: BCOVPlaybackController?
    
    private lazy var playbackService: BCOVPlaybackService = {
        return BCOVPlaybackService(accountId: PlayerConfig.PlaybackConfig.AccountID, policyKey: PlayerConfig.PlaybackConfig.PolicyKey)
    }()
    
    private var notificationReceipt: AnyObject?
    private var adIsPlaying = false
    private var isBrowserOpen = false
    
    // MARK: - View Lifecyle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let _ = playerView
        
        setupPlaybackController()
        resumeAdAfterForeground()
        
        if #available(iOS 14, *) {
            ATTrackingManager.requestTrackingAuthorization { [weak self] (status: ATTrackingManager.AuthorizationStatus) in
                DispatchQueue.main.async {
                    self?.requestContentFromPlaybackService()
                }
            }
        } else {
            requestContentFromPlaybackService()
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(true)
        self.playerView?.performScreenTransition(with: .full)
        self.playbackController?.shutter = true
    }

    // MARK: - Misc
    
    func setupPlaybackController() {
        // NO-OP
    }
    
    func updateVideo(_ video: BCOVVideo) -> BCOVVideo {
        return video
    }
    
    private func resumeAdAfterForeground() {
        // When the app goes to the background, the Google IMA library will pause
        // the ad. This code demonstrates how you would resume the ad when entering
        // the foreground.
        
        notificationReceipt = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] (notificatin: Notification) in
            guard let strongSelf = self else {
                return
            }
            
            if strongSelf.adIsPlaying && !strongSelf.isBrowserOpen {
                strongSelf.playbackController?.resumeAd()
            }
        }
    }
    
    private func requestContentFromPlaybackService() {
        
        // In order to play back content, we are going to request a playlist from the
        // playback service (Video Cloud Playback API). The data from the service does
        // not have the required VMAP tag on the video, so this code demonstrates how
        // to update a playlist to set the ad tags on the video. You are responsible
        // for determining where the ad tag should originate from. We advise that if
        // you choose to hard code it into your app, that you provide a mechanism to
        // update it without having to submit an update to your app.
        
        playbackService.findVideo(withVideoID: PlayerConfig.PlaybackConfig.VideoID, parameters: nil) { [weak self] (video: BCOVVideo?, jsonResponse: [AnyHashable:Any]?, error: Error?) in
            
            if let video = video {
                
                let playlist = BCOVPlaylist(video: video)
                let updatedPlaylist = playlist?.update({ (mutablePlaylist: BCOVMutablePlaylist?) in
                    
                    guard let mutablePlaylist = mutablePlaylist else {
                        return
                    }
                    
                    var updatedVideos:[BCOVVideo] = []
                    
                    for video in mutablePlaylist.videos {
                        if let strongSelf = self, let _video = video as? BCOVVideo {
                            updatedVideos.append(strongSelf.updateVideo(_video))
                        }
                    }
                    
                    mutablePlaylist.videos = updatedVideos
                    
                })
                
                if let _updatedPlaylist = updatedPlaylist {
                    self?.playbackController?.setVideos(_updatedPlaylist.videos as NSFastEnumeration)
                }
            }
            
            if let error = error {
                print("Error retrieving video: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - BCOVPlaybackControllerDelegate

extension BaseViewController: BCOVPlaybackControllerDelegate {
    
    func playbackController(_ controller: BCOVPlaybackController!, didAdvanceTo session: BCOVPlaybackSession!) {
        print("ViewController Debug - Advanced to new session.")
    }
    
    func playbackController(_ controller: BCOVPlaybackController!, playbackSession session: BCOVPlaybackSession!, didReceive lifecycleEvent: BCOVPlaybackSessionLifecycleEvent!) {
        // Ad events are emitted by the BCOVIMA plugin through lifecycle events.
        // The events are defined BCOVIMAComponent.h.
        
        let type = lifecycleEvent.eventType
        
        // Prevent main content from showing up before the ad
        
        if type == kBCOVPlaybackSessionLifecycleEventPlay {
            self.playbackController?.shutter = false
        }
        
        if type == kBCOVIMALifecycleEventAdsLoaderLoaded {
            print("ViewController Debug - Ads loaded.")
            
            // When ads load successfully, the kBCOVIMALifecycleEventAdsLoaderLoaded lifecycle event
            // returns an NSDictionary containing a reference to the IMAAdsManager.
            guard let adsManager = lifecycleEvent.properties[kBCOVIMALifecycleEventPropertyKeyAdsManager] as? IMAAdsManager else {
                return
            }
            
            // Lower the volume of ads by half.
            adsManager.volume = adsManager.volume / 2.0
            let volumeString = String(format: "%0.1", adsManager.volume)
            print("ViewController Debug - IMAAdsManager.volume set to \(volumeString)")
            
        } else if type == kBCOVIMALifecycleEventAdsManagerDidReceiveAdEvent {
            
            guard let adEvent = lifecycleEvent.properties["adEvent"] as? IMAAdEvent else {
                return
            }
            
            switch adEvent.type {
            case .STARTED:
                print("ViewController Debug - Ad Started.")
                adIsPlaying = true
            case .COMPLETE:
                print("ViewController Debug - Ad Completed.")
                adIsPlaying = false
            case .ALL_ADS_COMPLETED:
                print("ViewController Debug - All ads completed.")
            default:
                break
            }
        }
    }
}

// MARK: - BCOVIMAPlaybackSessionDelegate

extension BaseViewController: BCOVIMAPlaybackSessionDelegate {

    func willCallIMAAdsLoaderRequestAds(with adsRequest: IMAAdsRequest!, forPosition position: TimeInterval) {
        // for demo purposes, increase the VAST ad load timeout.
        adsRequest.vastLoadTimeout = 3000.0
        let timeoutStringFormat = String(format: "%.1", adsRequest.vastLoadTimeout)
        print("ViewController Debug - IMAAdsRequest.vastLoadTimeout set to \(timeoutStringFormat) milliseconds.")
    }

}

// MARK: - IMAWebOpenerDelegate

extension BaseViewController: IMAWebOpenerDelegate {
    
    func webOpenerDidClose(inAppBrowser webOpener: NSObject!) {
        // Called when the in-app browser has closed.
        playbackController?.resumeAd()
    }
    
}
