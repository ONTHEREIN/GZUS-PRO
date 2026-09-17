#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint reshub_flutter.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'reshub_flutter'
  s.version          = '0.0.27'
  s.summary          = 'Flutter版本的shiply资源sdk'
  s.description      = <<-DESC
Flutter版本的shiply资源sdk
                       DESC
  s.homepage         = 'https://git.woa.com/RFlutter/packages/reshub_flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Tencent' => 'mellowxu@tencent.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'
  s.platform = :ios, '8.0'
  s.static_framework = true

  s.default_subspecs = 'PlanB'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'NO', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.subspec 'PlanA' do |ss| 
    ss.dependency 'ResHub/Core', '>= 1.10.23-rc.11'
    ss.dependency 'ResHub/Patch', '>= 1.10.23-rc.11'
    ss.dependency 'ResHub/DownloadImpl', '>= 1.10.23-rc.11'
    ss.dependency 'ResHub/FileImpl', '>= 1.10.23-rc.11'
    ss.dependency 'RDelivery/Core', '>= 1.3.6.11'
    ss.dependency 'RDelivery/DefaultLogImpl', '>= 1.3.6.11'
    ss.dependency 'RDelivery/DefaultStorageImpl', '>= 1.3.6.11'
    ss.dependency 'RDelivery/DefaultNetworkImpl', '>= 1.3.6.11'
    ss.dependency 'RDelivery/DefaultJsonModelImpl', '>= 1.3.6.11'
  end
  s.subspec 'PlanB' do |ss|
    ss.xcconfig = { 'GCC_PREPROCESSOR_DEFINITIONS' => 'SHIPLY_COMMERCIAL_VERSION=1' }
    ss.dependency 'ShiplyResHub', '>= 1.10.23-rc.11'
    ss.dependency 'ShiplyRDelivery', '>= 1.3.6.11'
  end
end
