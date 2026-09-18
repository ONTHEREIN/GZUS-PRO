import 'dart:io';

import 'package:flutter/widgets.dart';

ImageProvider<Object> localBackgroundImageProvider(String path) =>
    FileImage(File(path));
