# frozen_string_literal: true

RSpec.describe Github do
  it "creates oauth client" do
    expect(Config).to receive_messages(github_app_client_id: "client_id", github_app_client_secret: "client_secret")
    expect(Octokit::Client).to receive(:new).with(client_id: "client_id", client_secret: "client_secret")

    described_class.oauth_client
  end

  it "creates app client" do
    expect(Time).to receive(:now).and_return(Time.utc(2025, 11, 11)).at_least(:once)
    expect(Config).to receive(:github_app_id).and_return("123456")
    expect(Config).to receive(:github_app_private_key).and_return(<<~TEST_2048_KEY)
      -----BEGIN RSA PRIVATE KEY-----
      MIIEowIBAAKCAQEAngqvkcX0bcSL26Rm9jEeRCVib65mb6knDQQflZvTcDTkVa7Y
      HVMBBBXfD/JRk/e58mJwnDesjiUMsk/0pYjapI1GTxq+F/86ixpwEsg5FfP4vzAO
      zRFZfLHsw3wPgCIyMms4SuVv9nV7ECE4af+EaySCluvT0EQmWKZy1wPzbvqYOaC9
      Tqy9O+/831BvoO8avQgQnKv+KKdP7tcPBe+FIvYrJ+OXa5PP4hCSupkRg8kem/5N
      vWNFWxCEg2OEb4FyuQepNmNfVTCf0MGg+9CnUbD5ok6p+PoUTS7RCjyDvyr1U46F
      SzzeH2FZTbfr1oZemqj1qeIeMx5xdYdrprUzkwIDAQABAoIBABih1Lx1LIQhQqUg
      qhWMEUoQw5dhiMC1jgsWze9tApb1/3KlVjS316wx1nrvSyyzSy2Ojzuh58id2K1A
      DgLw4hcMl91Db0ZhNtgwbjBXOaKEzIvL6zqmDhsDxkGvp+DSM52tHXB68yjoJZ6d
      duP6ecKTRbFNH03SGWHuy25cxMfSkyemI2R3UhTac4r7FKrKofOZpHpVOIir+yrI
      eGzGwj5mKGrBd4EF5iaD0diSWtNuEJW+6Y+6hHJ3ZFUfZX7lqWuN+tlsS+bbz7oz
      1xd66lnPL2VWndaDFgk09VjfIQb4hY+p6GpwvdahBKwwja8ZbWAbvW3/LNABWyk1
      NYvSM5ECgYEA11B5Gqomut1bbJ/xHqKJ1dyAQYm0QlTs9vB6WUC6Lz0FwiJ2iIdh
      Vr1VSZBMhhN9YTDxVF2r364tWCOye79ZaRKsigRyBOcPAbdkfKPnq/uHQxEZ0Q1d
      7M+gxCYQx0iw02CySDklc1H9qDA0E86DYdGErR3fbltRXkHxjWyezNECgYEAu+e7
      QHutzqLjGWDT2lbFSiJkZMwsh/Aiwv0K/SRT/7eWsQCqxJGufX50rQqqSw8ICI9d
      vhkGoKj+hX7QNWeVkKShD5ierT67ou+O28EvP50NEv8uE3m3O6VUPhfTN+FRITRm
      N7lA+elzTFWJT4ZpQVfRs6hg5rmiXU84UPY8wyMCgYB8usx9CuaGx6anpXvbwFLS
      xfqyfKAk8OeZIbPuslVo+hO045wA+VQFGIcop2P9I5s1S1HyCpV/bXotHfjOQQn9
      mWjER1D50BRcbS3UGmshsQMpceWfufuYLKs4FckQeOaefNyqhBhS1sN3w/zXIIHx
      j5spYi3F0zauwMq6n5rakQKBgQC235Kn8TZ4kqJ+wnOsXSJpQgt+5g64xgauymJ1
      d3OgveYUodeQs0+kpvuapXSS1DA3VIAhUG3Y0l/TQFYWg5dWTELL0PctGI64xni8
      esknGgvtXxhSr/SaQg841ysjiU/SBxMsTElmb8NcmSqnkOLDS1q1hLu6ERRpx33B
      ncQJDQKBgAcxG6nYMX8YtEFVDmdgjeAae2wiaK7cPEmJpzNptwnUUciSpyLJjWcl
      kezzHuHDhhVNqiHvN4xYHdpPv2BZXHAQoWcR3zkm9IyguqWSWxKlGCS9ImBOcVS4
      zYtLyDpE6nVc6P5CER0+7MRRP/6iPgSnaqXSJLCAvb5R0K+URHrs
      -----END RSA PRIVATE KEY-----
    TEST_2048_KEY

    expect(Octokit::Client).to receive(:new).with(bearer_token: "eyJhbGciOiJSUzI1NiJ9.eyJpYXQiOjE3NjI4MTkyMDAsImV4cCI6MTc2MjgxOTY4MCwiaXNzIjoiMTIzNDU2In0.iMTR9OO7pZbG9WR5_brak0frQ8XmRPMPQIbE0_spLOL19PX7dxXSQNg-lHxmJP3tghiW7TIgx6-8mY4--ZNKPgTpnwgi_qsgg5IkzM6r2t6XfNV-pFcBsoGas2pHXfitnCWpwHlWj17SZ-AoVkp4VsURJwuBwlNOBVDO4R4bzHZbgA_Xw7lu8OQGnfOm1AzCM4jD6AR22hGdVCkpORXiI4mSi1xdHoP6ARnB6GV6jeRSG41gJLteV6zBZjoVCe7MYSOcmw4RZ4coLR2frRYLyoAAPLqFGDAmJdtxame9fKiXbwflBUTVHaSNl0a-YyseifUysM5Z9GOY1ky7vnzmwg")
    described_class.app_client
  end

  it "creates installation client" do
    installation_id = 123
    app_client = instance_double(Octokit::Client)
    expect(described_class).to receive(:app_client).and_return(app_client)
    expect(app_client).to receive(:create_app_installation_access_token).with(installation_id).and_return({token: "abcdefg"})
    installation_client = instance_double(Octokit::Client)
    expect(installation_client).to receive(:auto_paginate=).with(true)
    expect(Octokit::Client).to receive(:new).with(access_token: "abcdefg").and_return(installation_client)

    described_class.installation_client(installation_id)
  end

  it "can map alias to actual label" do
    labels = described_class.runner_labels
    expect(labels["ubicloud"]).to eq(labels["ubicloud-standard-2-ubuntu-2404"])
    expect(labels["ubicloud-standard-8"]).to eq(labels["ubicloud-standard-8-ubuntu-2404"])
    expect(labels["ubicloud-standard-4-arm"]).to eq(labels["ubicloud-standard-4-arm-ubuntu-2404"])
  end

  it "can map all aliases to actual tag" do
    expect(described_class.runner_labels.values).to be_all
  end
end
