import 'package:better_player/better_player.dart';
import 'package:better_player_example/constants.dart';
import 'package:better_player_example/download_source.dart';
import 'package:flutter/material.dart';

class HlsAudioPage extends StatefulWidget {
  @override
  _HlsAudioPageState createState() => _HlsAudioPageState();
}

class _HlsAudioPageState extends State<HlsAudioPage> {
  late BetterPlayerController _betterPlayerController;
  late BetterPlayerDataSource _dataSource;

  @override
  void initState() {
    BetterPlayerConfiguration betterPlayerConfiguration =
        BetterPlayerConfiguration(
      aspectRatio: 16 / 9,
      fit: BoxFit.contain,
    );
    _dataSource = BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      Constants.elephantDreamStreamUrl,
    );
    _betterPlayerController = BetterPlayerController(betterPlayerConfiguration);
    _betterPlayerController.setupDataSource(_dataSource);
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("HLS Audio"),
      ),
      body: Column(
        children: [
          const SizedBox(height: 8),
          DownloadSource(dataSource: _dataSource),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              "Click on overflow menu (3 dots) and select Audio. You can choose "
              "audio track from HLS stream. Better Player will setup audio"
              " automatically for you.",
              style: TextStyle(fontSize: 16),
            ),
          ),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: BetterPlayer(controller: _betterPlayerController),
          ),
        ],
      ),
    );
  }
}
