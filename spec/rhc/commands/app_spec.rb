require 'spec_helper'
require 'rest_spec_helper'
require 'rhc/commands/app'
require 'rhc/config'
require 'resolv'

describe RHC::Commands::App do
  let!(:rest_client){ MockRestClient.new }
  let!(:config){ user_config }
  before{ RHC::Config.stub(:home_dir).and_return('/home/mock_user') }
  before do
    FakeFS.activate!
    FakeFS::FileSystem.clear
    RHC::Helpers.send(:remove_const, :MAX_RETRIES) rescue nil
    RHC::Helpers.const_set(:MAX_RETRIES, 3)
    @instance = RHC::Commands::App.new
    RHC::Commands::App.stub(:new) do
      @instance.stub(:git_config_get) { "" }
      @instance.stub(:git_config_set) { "" }
      Kernel.stub(:sleep) { }
      @instance.stub(:git_clone_repo) do |git_url, repo_dir|
        raise RHC::GitException, "Error in git clone" if repo_dir == "giterrorapp"
        Dir::mkdir(repo_dir)
      end
      @instance.stub(:host_exists?) do |host|
        host.match("dnserror") ? false : true
      end
      @instance
    end
  end

  after(:each) do
    FakeFS.deactivate!
  end

  describe 'app default' do
    before(:each) do
      FakeFS.deactivate!
    end

    context 'app' do
      let(:arguments) { ['app'] }
      it { run_output.should match('Usage:') }
    end
  end

  describe '#gear_group_state' do
    it("shows single state"){ subject.send(:gear_group_state, ['started']).should == 'started' }
    it("shows unique states"){ subject.send(:gear_group_state, ['idle', 'idle']).should == 'idle' }
    it("shows number of started"){ subject.send(:gear_group_state, ['started', 'idle']).should == '1/2 started' }
  end

  describe '#check_domain!' do
    let(:rest_client){ stub('RestClient') }
    let(:domain){ stub('Domain', :id => 'test') }
    before{ subject.stub(:rest_client).and_return(rest_client) }
    let(:interactive){ false }
    before{ subject.stub(:interactive?).and_return(interactive) }

    context "when no options are provided and there is one domain" do
      before{ rest_client.should_receive(:domains).twice.and_return([domain]) }
      it("should load the first domain"){ subject.send(:check_domain!).should == domain }
      after{ subject.send(:options).namespace.should == domain.id }
    end

    context "when no options are provided and there are no domains" do
      before{ rest_client.should_receive(:domains).and_return([]) }
      it("should load the first domain"){ expect{ subject.send(:check_domain!) }.to raise_error(RHC::Rest::DomainNotFoundException) }
      after{ subject.send(:options).namespace.should be_nil }
    end

    context "when valid namespace is provided" do
      before{ subject.send(:options)[:namespace] = 'test' }
      before{ rest_client.should_receive(:find_domain).with('test').and_return(domain) }
      it("should load the requested domain"){ subject.send(:check_domain!).should == domain }
      after{ subject.send(:options).namespace.should == 'test' }
    end

    context "when interactive and no domains" do
      let(:interactive){ true }
      before{ rest_client.should_receive(:domains).twice.and_return([]) }
      before{ RHC::DomainWizard.should_receive(:new).and_return(stub(:run => true)) }
      it("should raise if the wizard doesn't set the option"){ expect{ subject.send(:check_domain!) }.to raise_error(RHC::Rest::DomainNotFoundException) }
      after{ subject.send(:options).namespace.should be_nil }
    end
  end

  describe 'app create' do
    before{ rest_client.add_domain("mockdomain") }

    context "when we ask for help with the alias" do
      before{ FakeFS.deactivate! }
      context do
        let(:arguments) { ['help', 'create-app'] }
        it{ run_output.should match "Usage: rhc app-create <name>" }
      end
      context do
        let(:arguments) { ['create-app', '-h'] }
        it{ run_output.should match "Usage: rhc app-create <name>" }
      end
    end

    context "when run with no arguments" do
      before{ FakeFS.deactivate! }
      let(:arguments){ ['create-app'] }
      it{ run_output.should match "Usage: rhc app-create <name>" }
      it{ run_output.should match "When creating an application, you must provide a name and a cartridge from the list below:" }
      it{ run_output.should match "mock_standalone_cart-1" }
      it{ run_output.should match "Please specify the name of the application" }
    end

    context "when dealing with config" do
      subject{ described_class.new(Commander::Command::Options.new(options)) }
      let(:wizard){ s = stub('Wizard'); RHC::EmbeddedWizard.should_receive(:new).and_return(s); s }
      let(:options){ nil }
      let(:interactive){ true }
      before{ subject.should_receive(:interactive?).at_least(1).times.and_return(interactive) }
      before{ subject.stub(:check_sshkeys!) }

      it("should run the wizard"){ expect{ subject.create('name', ['mock_standalone_cart-1']) }.to call(:run).on(wizard).and_stop }

      context "when has config" do
        let(:options){ {:server => 'test', :rhlogin => 'foo'} }
        before{ subject.send(:config).should_receive(:has_local_config?).and_return(true) }
        it("should not run the wizard"){ expect{ subject.create('name', ['mock_standalone_cart-1']) }.to not_call(:new).on(RHC::EmbeddedWizard) }
      end

      context "when has no config" do
        before{ subject.send(:config).should_receive(:has_local_config?).and_return(false) }
        it("should run the wizard"){ expect{ subject.create('name', ['mock_standalone_cart-1']) }.to call(:new).on(RHC::EmbeddedWizard).and_stop }
      end

      context "when not interactive" do
        let(:interactive){ false }
        it("should not run the wizard"){ expect{ subject.create('name', ['mock_standalone_cart-1']) }.to not_call(:new).on(RHC::EmbeddedWizard) }
      end
    end

    context "when dealing with ssh keys" do
      subject{ described_class.new(options) }
      let(:wizard){ s = stub('Wizard'); RHC::SSHWizard.should_receive(:new).and_return(s); s }
      let(:options){ Commander::Command::Options.new(:server => 'foo.com', :rhlogin => 'test') }
      let(:interactive){ true }
      before{ subject.should_receive(:interactive?).at_least(1).times.and_return(interactive) }
      before{ subject.should_receive(:check_config!) }

      it("should run the wizard"){ expect{ subject.create('name', ['mock_standalone_cart-1']) }.to call(:run).on(wizard).and_stop }

      context "when not interactive" do
        let(:interactive){ false }
        it("should not run the wizard"){ expect{ subject.create('name', ['mock_standalone_cart-1']) }.to not_call(:new).on(RHC::SSHWizard) }
      end
    end

    context "when in full interactive mode with no keys, domain, or config" do
      let!(:config){ base_config }
      before{ RHC::Config.any_instance.stub(:has_local_config?).and_return(false) }
      before{ described_class.any_instance.stub(:interactive?).and_return(true) }
      before{ rest_client.domains.clear }
      let(:arguments) { ['app', 'create', 'app1', 'mock_standalone_cart-1'] }
      # skips login stage and insecure check because of mock rest client, doesn't check keys
      it { run_output(['mydomain', 'y', 'mykey']).should match(/This wizard.*Checking your namespace.*Your domain name 'mydomain' has been successfully created.*Creating application.*Your public SSH key.*Uploading key 'mykey' .*Downloading the application.*Success/m) }
    end

    context 'when run without a cart' do
      before{ FakeFS.deactivate! }
      let(:arguments) { ['app', 'create', 'app1', '--noprompt', '--timeout', '10', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password'] }
      it { run_output.should match(/mock_standalone_cart-1.*Every application needs a web cartridge/m) }
    end

    context 'when run with a valid cart' do
      let(:arguments) { ['app', 'create', 'app1', 'mock_standalone_cart-1', '--noprompt', '--timeout', '10', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password'] }
      it { expect { run }.to exit_with_code(0) }
      it { run_output.should match("Success") }
      it { run_output.should match("Cartridges: mock_standalone_cart-1\n") }
    end

    context 'when Hosts resolver raises an Exception' do
      let(:arguments) { ['app', 'create', 'app1', 'mock_standalone_cart-1', '--noprompt', '--timeout', '10', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password'] }
      before :each do
        resolver = Object.new
        Resolv::Hosts.should_receive(:new).and_return(resolver)
        resolver.should_receive(:getaddress).with('app1-mockdomain.fake.foo').and_raise(ArgumentError)
      end

      it { expect { run }.to exit_with_code(0) }
      it { run_output.should match("Success") }
    end

    context 'when run with multiple carts' do
      let(:arguments) { ['app', 'create', 'app1', 'mock_standalone_cart-1', 'mock_cart-1', '--noprompt', '-p',  'password'] }
      it { expect { run }.to exit_with_code(0) }
      it { run_output.should match("Success") }
      it { run_output.should match("Cartridges: mock_standalone_cart-1, mock_cart-1\n") }
      after{ rest_client.domains.first.applications.first.cartridges.find{ |c| c.name == 'mock_cart-1' }.should be_true }
    end

    context 'when run with a git url' do
      let(:arguments) { ['app', 'create', 'app1', 'mock_standalone_cart-1', '--from', 'git://url', '--noprompt', '-p',  'password'] }
      it { expect { run }.to exit_with_code(0) }
      it { run_output.should match("Success") }
      it { run_output.should match("Source Code: git://url\n") }
      it { run_output.should match("Initial Git URL: git://url\n") }
      after{ rest_client.domains.first.applications.first.initial_git_url.should == 'git://url' }
    end

    context 'when no cartridges are returned' do
      before(:each) do
        domain = rest_client.domains.first
      end
      context 'without trace' do
        let(:arguments) { ['app', 'create', 'app1', 'nomatch_cart', '--noprompt', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password'] }
        it("should display the list of cartridges") { run_output.should match(/Short Name.*mock_standalone_cart-2/m) }
      end
      context 'with trace' do
        let(:arguments) { ['app', 'create', 'app1', 'nomatch_cart', '--noprompt', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password', '--trace'] }
        it { expect { run }.to raise_error(RHC::CartridgeNotFoundException, "There are no cartridges that match 'nomatch_cart'.") }
      end
    end

  end

  describe 'cart matching behavior' do
    before(:each) do
      domain = rest_client.add_domain("mockdomain")
    end

    context 'multiple web matches' do
      let(:arguments) { ['app', 'create', 'app1', 'mock_standalone_cart', '--trace', '--noprompt'] }
      it { expect { run }.to raise_error(RHC::MultipleCartridgesException) }
    end
    context 'when only a single cart can match' do
      let(:arguments) { ['app', 'create', 'app1', 'unique', '--trace', '--noprompt'] }
      it('picks the cart') { run_output.should match('Using mock_unique_standalone_cart-1') }
    end
    context 'when I pick a web cart and an ambiguous non web cart' do
      let(:arguments) { ['app', 'create', 'app1', 'mock_standalone_cart-1', 'unique', '--trace', '--noprompt'] }
      it('picks the non web cart') { run_output.should match('Using unique_mock_cart-1') }
    end
    context 'when I pick very ambiguous carts' do
      let(:arguments) { ['app', 'create', 'app1', 'mock', '--noprompt'] }
      it('shows only web carts') { run_output.should_not match('unique_mock_cart-1') }
    end
    context 'when I pick only embedded carts' do
      let(:arguments) { ['app', 'create', 'app1', 'mock_cart', '--trace', '--noprompt'] }
      it { expect { run }.to raise_error(RHC::CartridgeNotFoundException, /Every application needs a web cartridge/) }
    end
    context 'when I pick multiple embedded carts' do
      let(:arguments) { ['app', 'create', 'app1', 'unique_standalone', 'mock_cart', '--trace', '--noprompt'] }
      it { expect { run }.to raise_error(RHC::MultipleCartridgesException, /There are multiple cartridges matching 'mock_cart'/) }
    end
    context 'when I pick multiple standalone carts' do
      let(:arguments) { ['app', 'create', 'app1', 'unique_standalone', 'mock_standalone_cart', '--trace', '--noprompt'] }
      it { expect { run }.to raise_error(RHC::MultipleCartridgesException, /You must select only a single web cart/) }
    end
  end

  describe 'app create enable-jenkins' do
    let(:arguments) { ['app', 'create', 'app1', '--trace', 'mock_unique_standalone_cart', '--enable-jenkins', '--noprompt', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password'] }

    context 'when run' do
      before(:each) do
        @domain = rest_client.add_domain("mockdomain")
      end
      it "should create a jenkins app and a regular app with an embedded jenkins client" do
        #puts run_output
        expect { run }.to exit_with_code(0)
        jenkins_app = rest_client.find_application(@domain.id,"jenkins")
        jenkins_app.cartridges[0].name.should == "jenkins-1.4"
        app = rest_client.find_application(@domain.id,"app1")
        app.find_cartridge("jenkins-client-1.4")
      end
    end
  end

  describe 'app create enable-jenkins with --no-dns' do
    let(:arguments) { ['app', 'create', 'app1', 'mock_unique_standalone_cart', '--trace', '--enable-jenkins', '--no-dns', '--noprompt', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password'] }

    context 'when run' do
      before(:each) do
        domain = rest_client.add_domain("mockdomain")
      end
      it { expect { run }.to_not raise_error(ArgumentError, /The --no-dns option can't be used in conjunction with --enable-jenkins/) }
    end
  end

  describe 'app create enable-jenkins with same name as app' do
    let(:arguments) { ['app', 'create', 'app1', 'mock_unique_standalone_cart', '--trace', '--enable-jenkins', 'app1', '--noprompt', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password'] }

    context 'when run' do
      before(:each) do
        domain = rest_client.add_domain("mockdomain")
      end
      it { expect { run }.to raise_error(ArgumentError, /You have named both your main application and your Jenkins application/) }
    end
  end

  describe 'app create enable-jenkins with existing jenkins' do
    let(:arguments) { ['app', 'create', 'app1', 'mock_unique_standalone_cart', '--trace', '--enable-jenkins', 'jenkins2', '--noprompt', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password'] }

    context 'when run' do
      before(:each) do
        @domain = rest_client.add_domain("mockdomain")
        @domain.add_application("jenkins", "jenkins-1.4")
      end
      it "should use existing jenkins" do
        expect { run }.to exit_with_code(0)
        expect { rest_client.find_application(@domain.id,"jenkins") }.to_not raise_error
        expect { rest_client.find_application(@domain.id,"jenkins2") }.to raise_error(RHC::Rest::ApplicationNotFoundException)
      end
    end
  end

  describe 'app create jenkins fails to install warnings' do
    let(:arguments) { ['app', 'create', 'app1', 'mock_unique_standalone_cart', '--enable-jenkins', '--noprompt', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password'] }

    before(:each) do
      @domain = rest_client.add_domain("mockdomain")
    end

    context 'when run with error in jenkins setup' do
      before(:each) do
        @instance.stub(:add_jenkins_app) { raise Exception }
      end
      it "should print out jenkins warning" do
        run_output.should match("Jenkins failed to install")
      end
    end

    context 'when run with error in jenkins-client setup' do
      before(:each) do
        @instance.stub(:add_jenkins_cartridge) { raise Exception }
      end
      it "should print out jenkins warning" do
        run_output.should match("Jenkins client failed to install")
      end
    end
  end

  describe 'app create jenkins install with retries' do
    let(:arguments) { ['app', 'create', 'app1', 'mock_unique_standalone_cart', '--enable-jenkins', '--noprompt', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password'] }

    context 'when run with server error in jenkins-client setup' do
      before(:each) do
        @domain = rest_client.add_domain("mockdomain")
        @instance.stub(:add_jenkins_cartridge) { raise RHC::Rest::ServerErrorException.new("Server error", 157) }
      end
      it "should fail embedding jenkins cartridge" do
        Kernel.should_receive(:sleep).and_return(true)
        run_output.should match("Jenkins client failed to install")
      end
    end
  end

  describe 'dns app create warnings' do
    let(:arguments) { ['app', 'create', 'app1', 'mock_unique_standalone_cart', '--noprompt', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password'] }

    context 'when run' do
      before(:each) do
        @domain = rest_client.add_domain("dnserror")
      end
      it { run_output.should match("unable to lookup your hostname") }
    end
  end

  describe 'app create git warnings' do
    let(:arguments) { ['app', 'create', 'app1', 'mock_unique_standalone_cart', '--noprompt', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password'] }

    before(:each) do
      @domain = rest_client.add_domain("mockdomain")
      @instance.stub(:git_clone_application) { raise RHC::GitException }
      @instance.stub(:check_sshkeys!)
    end

    context 'when run with error in git clone' do
      it "should print out git warning" do
        run_output.should match("We were unable to clone your application's git repo")
      end
    end

    context 'when run with windows and no nslookup bug' do
      before(:each) do
        RHC::Helpers.stub(:windows?) { true }
        @instance.stub(:run_nslookup) { true }
        @instance.stub(:run_ping) { true }
      end
      it "should print out git warning" do
        run_output.should match(" We were unable to clone your application's git repo")
      end
    end

    context 'when run with windows nslookup bug' do
      before(:each) do
        RHC::Helpers.stub(:windows?) { true }
        @instance.stub(:run_nslookup) { true }
        @instance.stub(:run_ping) { false }
      end
      it "should print out windows warning" do
        run_output.should match("This may also be related to an issue with Winsock on Windows")
      end
    end
  end

  describe 'app create --nogit deprecated' do
    let(:arguments) { ['app', 'create', 'app1', 'mock_unique_standalone_cart', '--noprompt', '--nogit', '--config', '/tmp/test.conf', '-l', 'test@test.foo', '-p',  'password'] }

    before (:each) do
      @domain = rest_client.add_domain("mockdomain")
    end

    context 'when run' do
      it { run_output.should match("The option '--nogit' is deprecated. Please use '--\\[no-\\]git' instead") }
    end
  end

  describe 'app create prompt for sshkeys' do
    let(:arguments) { ['app', 'create', 'app1', 'mock_unique_standalone_cart', '--config', '/tmp/test.conf', '-l', 'test@test.foo', '-p',  'password'] }

    before (:each) do
      @domain = rest_client.add_domain("mockdomain")
      # fakefs is activated
      Dir.mkdir('/tmp/')
      File.open('/tmp/test.conf', 'w') do |f|
        f.write("rhlogin=test@test.foo")
      end

      # don't run wizard here because we test this elsewhere
      wizard_instance = RHC::SSHWizard.new(rest_client, RHC::Config.new, Commander::Command::Options.new)
      wizard_instance.stub(:ssh_key_uploaded?) { true }
      RHC::SSHWizard.stub(:new) { wizard_instance }
      RHC::Config.stub(:should_run_ssh_wizard?) { false }
    end

    context 'when run' do
      it { expect { run }.to exit_with_code(0) }
    end
  end

  describe 'app delete' do
    let(:arguments) { ['app', 'delete', '--trace', '-a', 'app1', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password'] }

    context 'when run' do
      before{ @domain = rest_client.add_domain("mockdomain") }

      it "should raise cartridge not found exception when no apps exist" do
        expect { run }.to raise_error RHC::Rest::ApplicationNotFoundException
      end

      context "with an app" do
        before{ @app = @domain.add_application("app1", "mock_type") }

        it "should not remove app when no is sent as input" do
          expect { run(["no"]) }.to raise_error(RHC::ConfirmationError)
          @domain.applications.length.should == 1
          @domain.applications[0] == @app
        end

        it "should remove app when yes is sent as input" do
          expect { run(["yes"]) }.to exit_with_code(0)
          @domain.applications.length.should == 0
        end

        context "with --noprompt but without --confirm" do
          let(:arguments) { ['app', 'delete', 'app1', '--noprompt', '--trace'] }
          it "should not remove the app" do
            expect { run(["no"]) }.to raise_error(RHC::ConfirmationError)
            @domain.applications.length.should == 1
          end
        end
        context "with --noprompt and --confirm" do
          let(:arguments) { ['app', 'delete', 'app1', '--noprompt', '--confirm'] }
          it "should remove the app" do
            expect { run }.to exit_with_code(0)
            @domain.applications.length.should == 0
          end
        end
      end
    end
  end

  describe 'app show' do
    let(:arguments) { ['app', 'show', 'app1', '--noprompt', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password'] }

    context 'when run with the same case as created' do
      before(:each) do
        FakeFS.deactivate!
        @domain = rest_client.add_domain("mockdomain")
        @domain.add_application("app1", "mock_type")
      end
      it("should output an app") { run_output.should match("app1 @ https://app1-mockdomain.fake.foo/") }
      it { run_output.should match(/Gears:\s+1 small/) }
    end

    context 'when run with scaled app' do
      before(:each) do
        @domain = rest_client.add_domain("mockdomain")
        app = @domain.add_application("app1", "mock_type", true)
        cart1 = app.add_cartridge('mock_cart-1')
        cart2 = app.add_cartridge('mock_cart-2')
        cart2.gear_profile = 'medium'
      end
      it { run_output.should match("app1 @ https://app1-mockdomain.fake.foo/") }
      it { run_output.should match(/Scaling:.*x2/) }
      it { run_output.should match(/Gears:\s+Located with mock_type/) }
      it { run_output.should match(/Gears:\s+1 medium/) }
    end
  end

  describe 'app show' do
    let(:arguments) { ['app', 'show', 'APP1', '--noprompt', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password'] }

    context 'when run with the different case from created' do
      before(:each) do
        @rc = MockRestClient.new
        @domain = @rc.add_domain("mockdomain")
        @domain.add_application("app1", "mock_type")
      end
      it { run_output.should match("app1 @ https://app1-mockdomain.fake.foo/") }
    end
  end

  describe 'app show --state' do
    let(:arguments) { ['app', 'show', 'app1', '--state', '--noprompt', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password'] }

    context 'when run' do
      before(:each) do
        @domain = rest_client.add_domain("mockdomain")
        @domain.add_application("app1", "mock_type")
      end
      it { run_output.should match("started") }
    end
  end

  describe 'app show --gears' do
    let(:arguments) { ['app', 'show', 'app1', '--gears', '--noprompt'] }

    context 'when run' do
      before(:each) do
        @domain = rest_client.add_domain("mockdomain")
        @domain.add_application("app1", "mock_type")
      end
      it { run_output.should match("fakegearid started fake_geargroup_cart-0.1 small fakegearid@fakesshurl.com") }
    end
  end

  describe 'app ssh' do
    let(:arguments) { ['app', 'ssh', 'app1'] }

    context 'when run' do
      before(:each) do
        @domain = rest_client.add_domain("mockdomain")
        @domain.add_application("app1", "mock_type")
        Kernel.should_receive(:system).with("ssh fakeuuidfortestsapp1@127.0.0.1").and_return(0)
      end
      it { run_output.should match("Connecting to fakeuuidfortestsapp") }
      it { expect { run }.to exit_with_code(0) }
    end
  end

  describe 'app ssh no system ssh' do
    let(:arguments) { ['app', 'ssh', 'app1'] }

    context 'when run' do
      before(:each) do
        @domain = rest_client.add_domain("mockdomain")
        @domain.add_application("app1", "mock_type")
        @instance.should_receive(:has_ssh?).and_return(false)
      end
      it { run_output.should match("Please use the --ssh option to specify the path to your SSH executable, or install SSH.") }
      it { expect { run }.to exit_with_code(1) }
    end
  end

  describe 'app ssh can use system exec' do
    let(:arguments) { ['app', 'ssh', 'app1', '--ssh', 'path_to_ssh'] }

    context 'when run' do
      before(:each) do
        @domain = rest_client.add_domain("mockdomain")
        @domain.add_application("app1", "mock_type")
        @instance.should_not_receive(:has_ssh?)
        Kernel.should_receive(:system).with("path_to_ssh fakeuuidfortestsapp1@127.0.0.1").and_return(1)
      end
      it { run_output.should match("Connecting to fakeuuidfortestsapp") }
      it { expect { run }.to exit_with_code(1) }
    end
  end

  describe 'ssh tests' do
    let(:arguments) { ['app', 'ssh', 'app1', '-s /bin/blah'] }

    context 'has_ssh?' do
      before{ @instance.stub(:ssh_version){ raise "Fake Exception" } }
      its(:has_ssh?) { should be_false }
    end
  end

  describe 'app status' do
    let(:arguments) { ['app', 'status', 'app1', '--noprompt', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password'] }

    context 'when run' do
      before(:each) do
        @domain = rest_client.add_domain("mockdomain")
        @domain.add_application("app1", "mock_type")
      end
      it { run_output.should match("started") }
      it("should warn about deprecation") { run_output.should match("deprecated") }
    end
  end

  describe 'app actions' do

    before(:each) do
      domain = rest_client.add_domain("mockdomain")
      app = domain.add_application("app1", "mock_type")
      app.add_cartridge('mock_cart-1')
    end

    context 'app start' do
      let(:arguments) { ['app', 'start', '-a', 'app1','--noprompt', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password'] }
      it { run_output.should match('start') }
    end

    context 'app stop' do
      let(:arguments) { ['app', 'stop', 'app1','--noprompt', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password'] }

      it { run_output.should match('stop') }
    end

    context 'app force stop' do
      let(:arguments) { ['app', 'force-stop', 'app1','--noprompt', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password'] }

      it { run_output.should match('force') }
    end

    context 'app restart' do
      let(:arguments) { ['app', 'restart', 'app1','--noprompt', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password'] }
      it { run_output.should match('restart') }
    end

    context 'app reload' do
      let(:arguments) { ['app', 'reload', 'app1','--noprompt', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password'] }
      it { run_output.should match('reload') }
    end

    context 'app tidy' do
      let(:arguments) { ['app', 'tidy', 'app1','--noprompt', '--config', 'test.conf', '-l', 'test@test.foo', '-p',  'password'] }
      it { run_output.should match('cleaned') }
    end
  end

  describe "#create_app" do
    it("should list cartridges when a server error happens") do
      subject.should_receive(:list_cartridges)
      domain = stub
      domain.stub(:add_application).and_raise(RHC::Rest::ValidationException.new('Foo', :cartridges, 109))
      expect{ subject.send(:create_app, 'name', 'jenkins-1.4', domain) }.to raise_error(RHC::Rest::ValidationException)
    end
  end
end
