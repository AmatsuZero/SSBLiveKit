#
# Be sure to run `pod lib lint SSBLiveKit.podspec' to ensure this is a
# valid spec before submitting.
#
# Any lines starting with a # are optional, but their use is encouraged
# To learn more about a Podspec see https://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = 'SSBLiveKit'
  s.version          = '0.1.0'
  s.summary          = '一个直播SDK'

# This description is used to generate tags and improve search results.
#   * Think: What does it do? Why did you write it? What is the focus?
#   * Try to keep it short, snappy and to the point.
#   * Write the description between the DESC delimiters below.
#   * Finally, don't worry about the indent, CocoaPods strips it!

  s.description      = <<-DESC
优酷来疯直播SDK的Swift实现
                       DESC

  s.homepage         = 'https://github.com/AmatsuZero/SSBLiveKit'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'AmatsuZero' => 'jzh16s@hotmail.com' }
  s.source           = { :git => 'https://github.com/AmatsuZero/SSBLiveKit.git', :tag => s.version.to_s }
  # s.social_media_url = 'https://twitter.com/<TWITTER_USERNAME>'

  s.ios.deployment_target = '8.0'
  s.swift_version = '4.0'
  s.source_files = 'SSBLiveKit/Classes/**/*'
  s.module_map = "SSBLiveKit/../module.modulemap"
  s.frameworks = 'VideoToolbox'
  s.dependency 'SSBEncoder', '~> 0.1.0'
  s.dependency 'SSBFilter', '~> 0.1.0'

end
