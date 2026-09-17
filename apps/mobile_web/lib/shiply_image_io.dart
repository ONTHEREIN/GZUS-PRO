import 'dart:io';

import 'package:flutter/widgets.dart';

ImageProvider<Object> shiplyLocalImageProvider(String path) =>
    FileImage(File(path));
