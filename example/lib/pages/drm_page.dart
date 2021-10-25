import 'package:better_player/better_player.dart';
import 'package:better_player_example/constants.dart';
import 'package:better_player_example/download_source.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DrmPage extends StatefulWidget {
  @override
  _DrmPageState createState() => _DrmPageState();
}

class _DrmPageState extends State<DrmPage> {
  late BetterPlayerController _tokenController;
  late BetterPlayerController _widevineController;
  late BetterPlayerController _fairplayController;
  late BetterPlayerDataSource _fairplayDataSource;

  @override
  void initState() {
    BetterPlayerConfiguration betterPlayerConfiguration =
        BetterPlayerConfiguration(
      aspectRatio: 16 / 9,
      fit: BoxFit.contain,
    );
    // BetterPlayerDataSource _tokenDataSource = BetterPlayerDataSource(
    //   BetterPlayerDataSourceType.network,
    //   Constants.tokenEncodedHlsUrl,
    //   videoFormat: BetterPlayerVideoFormat.hls,
    //   drmConfiguration: BetterPlayerDrmConfiguration(
    //       drmType: BetterPlayerDrmType.token,
    //       token: Constants.tokenEncodedHlsToken),
    // );
    // _tokenController = BetterPlayerController(betterPlayerConfiguration);
    // _tokenController.setupDataSource(_tokenDataSource);

    // _widevineController = BetterPlayerController(betterPlayerConfiguration);
    // BetterPlayerDataSource _widevineDataSource = BetterPlayerDataSource(
    //   BetterPlayerDataSourceType.network,
    //   Constants.widevineVideoUrl,
    //   drmConfiguration: BetterPlayerDrmConfiguration(
    //       drmType: BetterPlayerDrmType.widevine,
    //       licenseUrl: Constants.widevineLicenseUrl,
    //       headers: {"Test": "Test2"}),
    // );
    // _widevineController.setupDataSource(_widevineDataSource);

    _fairplayController = BetterPlayerController(betterPlayerConfiguration);
    _fairplayDataSource = BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      Constants.fairplayHlsUrl,
      drmConfiguration: BetterPlayerDrmConfiguration(
        drmType: BetterPlayerDrmType.fairplay,
        // certificateUrl: Constants.fairplayCertificateUrl,
        // licenseUrl: Constants.fairplayLicenseUrl,
        // headers: {
        //   'Authorization':
        //       'Bearer=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1cm46bWljcm9zb2Z0OmF6dXJlOm1lZGlhc2VydmljZXM6Y29udGVudGtleWlkZW50aWZpZXIiOiJiNDFkMzY0Yi00MzNiLTQ4ZGUtOWQxZS01Zjg2NmYyOGI4YzMiLCJuYmYiOjE2MzQ3NDY0NzgsImV4cCI6MTYzNDc1MDM3OCwiaXNzIjoiYXVkaW9iaWJsZS1hcGkiLCJhdWQiOiJhdWRpb2JpYmxlLWNsaWVudF9hcHAifQ.ZWPHqRtwrx96jDUGfd1zPZIGEHx6JVqepzGEAMsJ5X0'
        // },
      ),
    );

    _fairplayController.setupDataSource(_fairplayDataSource).onError(
      (error, stackTrace) {
        if (error is PlatformException && error.code == "InvalidPersistenKey") {
          print("InvalidPersistenKey");
        }
      },
    );

    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("DRM player"),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // const SizedBox(height: 8),
            // Padding(
            //   padding: const EdgeInsets.symmetric(horizontal: 16),
            //   child: Text(
            //     "Auth token based DRM.",
            //     style: TextStyle(fontSize: 16),
            //   ),
            // ),
            // AspectRatio(
            //   aspectRatio: 16 / 9,
            //   child: BetterPlayer(controller: _tokenController),
            // ),
            // const SizedBox(height: 16),
            // Padding(
            //   padding: const EdgeInsets.symmetric(horizontal: 16),
            //   child: Text(
            //     "Widevine - license url based DRM. Works only for Android.",
            //     style: TextStyle(fontSize: 16),
            //   ),
            // ),
            // AspectRatio(
            //   aspectRatio: 16 / 9,
            //   child: BetterPlayer(controller: _widevineController),
            // ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                "Fairplay - certificate url based EZDRM. Works only for iOS.",
                style: TextStyle(fontSize: 16),
              ),
            ),
            const SizedBox(height: 8),
            DownloadSource(dataSource: _fairplayDataSource),
            AspectRatio(
              aspectRatio: 16 / 9,
              child: BetterPlayer(controller: _fairplayController),
            ),
            const SizedBox(height: 100),
          ],
        ),
      ),
    );
  }
}
