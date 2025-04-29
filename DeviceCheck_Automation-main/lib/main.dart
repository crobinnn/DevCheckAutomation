import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' show join;
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'package:image/image.dart' as img;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  final firstCamera = cameras.first;

  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: ServerConfigScreen(
        camera: firstCamera,
      ),
    ),
  );
}

class ServerConfigScreen extends StatelessWidget {
  final CameraDescription camera;

  const ServerConfigScreen({required this.camera});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Server Configuration')),
      body: Center(
        child: ElevatedButton(
          onPressed: () {
            _showServerConfigDialog(context, camera);
          },
          child: Text('Configure Server IP and Port'),
        ),
      ),
    );
  }

  void _showServerConfigDialog(BuildContext context, CameraDescription camera) {
    final TextEditingController ipController = TextEditingController();
    final TextEditingController portController = TextEditingController();

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text("Enter Server IP and Port"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ipController,
                decoration: InputDecoration(
                  hintText: 'Enter server IP',
                ),
              ),
              TextField(
                controller: portController,
                decoration: InputDecoration(
                  hintText: 'Enter server port',
                ),
                keyboardType: TextInputType.number,
              ),
            ],
          ),
          actions: [
            TextButton(
              child: Text("Cancel"),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            ElevatedButton(
              child: Text("Connect"),
              onPressed: () {
                String ip = ipController.text.trim();
                String port = portController.text.trim();

                if (ip.isNotEmpty && port.isNotEmpty) {
                  // Navigate to the camera screen with server info
                  Navigator.of(context).pop();
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                      builder: (context) => TakePictureScreen(
                        camera: camera,
                        serverIp: ip,
                        serverPort: int.tryParse(port) ??
                            8765, // Default port if parsing fails
                      ),
                    ),
                  );
                }
              },
            ),
          ],
        );
      },
    );
  }
}

class TakePictureScreen extends StatefulWidget {
  final CameraDescription camera;
  final String serverIp;
  final int serverPort;

  const TakePictureScreen({
    required this.camera,
    required this.serverIp,
    required this.serverPort,
  });

  @override
  TakePictureScreenState createState() => TakePictureScreenState();
}

class TakePictureScreenState extends State<TakePictureScreen> {
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;
  late WebSocketChannel _webSocketChannel;
  late Stream<dynamic> _webSocketBroadcastStream;

  String _serialNumber = 'N/A';
  String _macAddress = 'N/A';

  int _selectedLength = 10; // Default serial number length
  final List<int> _lengthOptions =
      List.generate(28, (index) => index + 3); // Options from 3 to 30

  // Shared storage for mappings
  List<Map<String, dynamic>> _mappings =
      []; // To store images with serial numbers and MAC addresses

  @override
  void initState() {
    super.initState();
    _controller = CameraController(
      widget.camera,
      ResolutionPreset.high,
    );

    _initializeControllerFuture = _controller.initialize();
    _initializeWebSocket();
  }

  void _initializeWebSocket() {
    try {
      _webSocketChannel = WebSocketChannel.connect(
        Uri.parse(
            'ws://${widget.serverIp}:${widget.serverPort}'), // Change to your server's IP
      );
      // Convert the WebSocket's stream to a broadcast stream for multiple listeners
      _webSocketBroadcastStream = _webSocketChannel.stream.asBroadcastStream();

      print('Connected to WebSocket server');
      _listenToServerResponse(); // Start listening to server responses
    } catch (e) {
      print('Error connecting to WebSocket server: $e');
    }
  }

  void _disconnectWebSocket(BuildContext context) {
    // Close the WebSocket connection
    _webSocketChannel.sink.close(status.normalClosure);
    // Navigate back to the ServerConfigScreen
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (context) => ServerConfigScreen(camera: widget.camera),
      ),
      (route) => false,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _webSocketChannel.sink.close(status.normalClosure);
    super.dispose();
  }

  Future<void> _takePicture() async {
    try {
      await _initializeControllerFuture;

      final XFile imageFile = await _controller.takePicture();

      // Save the image temporarily to the device
      final imagePath = join(
        (await getTemporaryDirectory()).path,
        '${DateTime.now()}.png',
      );

      // Move the XFile image to the desired location
      final File savedImage = File(imagePath);
      await savedImage.writeAsBytes(await imageFile.readAsBytes());

      // Read and crop the image to 1:1 aspect ratio
      final imageBytes = await savedImage.readAsBytes();
      final img.Image? originalImage = img.decodeImage(imageBytes);

      if (originalImage != null) {
        // Calculate the shortest side to make the square
        int shortestSide = originalImage.width < originalImage.height
            ? originalImage.width
            : originalImage.height;

        int cropX = (originalImage.width - shortestSide) ~/ 2; // Start x
        int cropY = (originalImage.height - shortestSide) ~/ 2; // Start y

        // Center-crop the image to make it 1:1
        final img.Image croppedImage = img.copyCrop(
          originalImage,
          x: cropX, // Start x
          y: cropY, // Start y
          width: shortestSide, // Width
          height: shortestSide, // Height
        );

        // Convert cropped image back to bytes
        final List<int> croppedImageBytes = img.encodePng(croppedImage);

        // Send cropped image bytes directly to the server as before
        _webSocketChannel.sink.add(croppedImageBytes);

        print("Cropped image bytes sent to server");
      } else {
        print("Failed to decode the image");
      }
    } catch (e) {
      print(e);
    }
  }

  void _listenToServerResponse() {
    _webSocketBroadcastStream.listen((message) {
      // Handle message decoding and display serial number and MAC address
      try {
        final response = jsonDecode(message);

        setState(() {
          _serialNumber = (response['serial_number'] is List &&
                  response['serial_number'].isNotEmpty)
              ? response['serial_number'][0]
              : 'N/A';

          _macAddress = (response['mac_address'] is List &&
                  response['mac_address'].isNotEmpty)
              ? response['mac_address'][0]
              : 'N/A';

          // Store the mapping
          _mappings.add({
            'image': _serialNumber, // Placeholder for image path or bytes
            'serial_number': _serialNumber,
            'mac_address': _macAddress,
          });
        });
      } catch (e) {
        print('Error decoding server response: $e');
      }
    });
  }

  void _sendLengthToServer(int length) {
    final lengthData = {'serial_length': length};
    String jsonString = jsonEncode(lengthData); // Ensure it is a JSON string
    _webSocketChannel.sink.add(jsonString); // Send the JSON string

    print("Sent serial number length to server: $length");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('DCF Scanner v1.0'),
        actions: [
          IconButton(
            icon: Icon(Icons.list),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => MappingsPage(
                      webSocketChannel: _webSocketChannel,
                      webSocketBroadcastStream: _webSocketBroadcastStream),
                ),
              );
            },
          ),
          IconButton(
            icon: Icon(
                Icons.logout), // Use a logout icon for the disconnect button
            onPressed: () => _disconnectWebSocket(context),
          ),
        ],
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          FutureBuilder<void>(
            future: _initializeControllerFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.done) {
                // Adjust this value to control the scaling of the preview

                return Center(
                    child: ClipRRect(
                  child: SizedOverflowBox(
                    size: const Size(350, 350), // aspect is 1:1
                    alignment: Alignment.center,
                    child: CameraPreview(_controller),
                  ),
                ));
              } else {
                return Center(child: CircularProgressIndicator());
              }
            },
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'S/N Length:',
                      style: TextStyle(fontSize: 16),
                    ),
                    SizedBox(width: 8), // Add space between label and dropdown
                    DropdownButton<int>(
                      value: _selectedLength,
                      onChanged: (int? newValue) {
                        setState(() {
                          _selectedLength = newValue!;
                          _sendLengthToServer(
                              _selectedLength); // Send selected length to server
                        });
                      },
                      items: _lengthOptions
                          .map<DropdownMenuItem<int>>((int value) {
                        return DropdownMenuItem<int>(
                          value: value,
                          child: Text('$value'),
                        );
                      }).toList(),
                    ),
                  ],
                ),
                // Dropdown button to select serial number length

                SizedBox(height: 40),
                Text(
                  'Serial Number: $_serialNumber',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  'MAC Address: $_macAddress',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _takePicture,
                  child: Text('Scan Image'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class MappingsPage extends StatefulWidget {
  final WebSocketChannel webSocketChannel;
  final Stream<dynamic> webSocketBroadcastStream;

  const MappingsPage(
      {Key? key,
      required this.webSocketChannel,
      required this.webSocketBroadcastStream})
      : super(key: key);
  @override
  _MappingsPageState createState() => _MappingsPageState();
}

class _MappingsPageState extends State<MappingsPage> {
  List<Map<String, dynamic>> _mappings = []; // Local storage for mappings
  bool _loading = true; // To indicate loading state

  @override
  void initState() {
    super.initState();
    _listenToServerResponse();
    _requestMappings(); // Request mappings when the page is initialized
  }

  Future<void> _saveMappingsToCache(List<Map<String, dynamic>> mappings) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> stringMappings =
        mappings.map((mapping) => jsonEncode(mapping)).toList();
    await prefs.setStringList('mappings', stringMappings);
  }

  Future<List<Map<String, dynamic>>> _loadMappingsFromCache() async {
    final prefs = await SharedPreferences.getInstance();
    List<String>? stringMappings = prefs.getStringList('mappings');
    if (stringMappings != null) {
      return stringMappings
          .map((mapping) => jsonDecode(mapping) as Map<String, dynamic>)
          .toList();
    }
    return [];
  }

  void _requestMappings() async {
    List<Map<String, dynamic>> cachedMappings = await _loadMappingsFromCache();
    setState(() {
      _mappings = cachedMappings; // Display cached mappings initially
      _loading = cachedMappings.isEmpty; // Show loading if no cached data
    });
    final requestData = {'get_mappings': true}; // Prepare the request data
    String jsonString = jsonEncode(requestData); // Convert to JSON string
    widget.webSocketChannel.sink
        .add(jsonString); // Send the request to the server
  }

  void _deleteMapping(int index) {
    // Create a delete message with the index
    final deleteMessage = jsonEncode({'delete_mapping': index});

    // Send the delete request to the server
    widget.webSocketChannel.sink.add(deleteMessage);

    // Optionally, remove the mapping locally for instant feedback
    setState(() {
      _mappings.removeAt(index);
    });

    print("Requested deletion of mapping at index: $index");
  }

  void _listenToServerResponse() {
    widget.webSocketBroadcastStream.listen((message) async {
      try {
        final response = jsonDecode(message);

        // Check if the response contains mappings
        if (response['mappings'] != null) {
          setState(() {
            _mappings = List<Map<String, dynamic>>.from(response['mappings']);
            _loading = false; // Update loading state
          });
          await _saveMappingsToCache(_mappings);
        }
      } catch (e) {
        print('Error decoding server response: $e');
      }
    });
  }

  void _showCreateDocumentsDialog() {
    final TextEditingController excelController = TextEditingController();
    final TextEditingController wordController = TextEditingController();

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text("Create Documents"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Title for Excel file input
              Container(
                alignment: Alignment.centerLeft, // Align text to the left
                child: Text("Excel File Name (without .xlsx):",
                    style: TextStyle(fontSize: 12)),
              ),
              TextField(
                controller: excelController,
              ),
              SizedBox(height: 16), // Add spacing between the fields
              // Title for Word file input
              Container(
                alignment: Alignment.centerLeft, // Align text to the left
                child: Text("Word File Name (without .docx):",
                    style: TextStyle(fontSize: 12)),
              ),
              TextField(
                controller: wordController,
              ),
            ],
          ),
          actions: [
            TextButton(
              child: Text("Cancel"),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            ElevatedButton(
              child: Text("Create"),
              onPressed: () {
                final excelFileName = '${excelController.text}.xlsx';
                final wordFileName = '${wordController.text}.docx';

                // Send message to the server
                final createDocumentsMessage = jsonEncode({
                  'create_documents': {
                    'excel_file': excelFileName,
                    'word_file': wordFileName,
                  },
                });

                widget.webSocketChannel.sink.add(createDocumentsMessage);
                print(
                    "Sent create documents request with filenames: $excelFileName, $wordFileName");
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Mappings'),
        actions: [
          IconButton(
            icon: Icon(Icons.add),
            onPressed: _showCreateDocumentsDialog,
          ),
        ],
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator()) // Show loading indicator
          : _mappings.isEmpty // Check if there are no mappings
              ? Center(child: Text('No mappings found'))
              : ListView.builder(
                  itemCount: _mappings.length,
                  itemBuilder: (context, index) {
                    final mapping = _mappings[index];
                    Uint8List? imageBytes;
                    if (mapping['image_data'] != null) {
                      try {
                        imageBytes = base64Decode(mapping['image_data']);
                      } catch (e) {
                        print('Error decoding image: $e');
                      }
                    }
                    return Card(
                      margin: EdgeInsets.all(8.0),
                      child: Padding(
                        padding: const EdgeInsets.all(10.0),
                        child: Row(
                          crossAxisAlignment:
                              CrossAxisAlignment.center, // Center vertically
                          children: [
                            // Display index number centered
                            Container(
                              width:
                                  30, // Adjust width for the number container
                              alignment: Alignment.center,
                              child: Text(
                                '${index + 1}', // Display 1, 2, 3, etc.
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            SizedBox(
                                width: 10), // Space between number and image

                            // Display image
                            if (imageBytes != null)
                              Image.memory(
                                imageBytes,
                                width: 100,
                                height: 100,
                                fit: BoxFit.cover,
                              )
                            else
                              Container(
                                width: 100,
                                height: 100,
                                color: Colors.grey[300],
                                child: Icon(Icons.image_not_supported),
                              ),

                            SizedBox(width: 15), // Space between image and text

                            // Display serial number and MAC address
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment
                                    .center, // Center content vertically
                                children: [
                                  // Serial Number Section
                                  Text(
                                    'Serial Number:',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                  ),
                                  SizedBox(
                                      height:
                                          2), // Small spacing between label and value
                                  Text(
                                    mapping['serial_number'].isNotEmpty
                                        ? mapping['serial_number'][0]
                                        : 'N/A',
                                    style: TextStyle(fontSize: 14),
                                  ),
                                  SizedBox(
                                      height:
                                          8), // Spacing between Serial Number and MAC Address

                                  // MAC Address Section
                                  Text(
                                    'MAC Address:',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                  ),
                                  SizedBox(
                                      height:
                                          2), // Small spacing between label and value
                                  Text(
                                    mapping['mac_address'].isNotEmpty
                                        ? mapping['mac_address'][0]
                                        : 'N/A',
                                    style: TextStyle(fontSize: 14),
                                  ),
                                ],
                              ),
                            ),
                            // Delete button
                            IconButton(
                              icon: Icon(Icons.delete, color: Colors.red),
                              onPressed: () {
                                _deleteMapping(index);
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
