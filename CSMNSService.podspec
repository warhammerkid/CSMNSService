Pod::Spec.new do |s|
  s.name         = 'CSMNSService'
  s.version      = '0.2.0'
  s.summary      = 'A bluetooth library for getting notifications from your phone when you get texts'
  s.platform     = :osx
  s.license      = 'MIT'
  s.homepage     = 'https://github.com/warhammerkid/CSMNSService'
  s.author       = { 'Stephen Augenstein' => 'perl.programmer@gmail.com' }
  s.source       = { :git => 'https://github.com/warhammerkid/CSMNSService.git', :tag => "v#{s.version}" }
  s.source_files = 'src/**/*.{h,m}'
  s.frameworks   = 'Foundation', 'IOBluetooth'
  s.requires_arc = false
end
