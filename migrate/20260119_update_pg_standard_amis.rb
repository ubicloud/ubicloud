# frozen_string_literal: true

Sequel.migration do
  up do
    [
      ["us-west-2", "x64", "16", "ami-07216deeaa235e092", "ami-0f8904e4361eb8be7"],
      ["us-west-2", "x64", "17", "ami-07216deeaa235e092", "ami-0f8904e4361eb8be7"],
      ["us-west-2", "x64", "18", "ami-07216deeaa235e092", "ami-0f8904e4361eb8be7"],
      ["us-east-1", "x64", "16", "ami-05453c5f8b6ee1699", "ami-0baca50c6f0398ccb"],
      ["us-east-1", "x64", "17", "ami-05453c5f8b6ee1699", "ami-0baca50c6f0398ccb"],
      ["us-east-1", "x64", "18", "ami-05453c5f8b6ee1699", "ami-0baca50c6f0398ccb"],
      ["us-east-2", "x64", "16", "ami-063af4d9afb2e908d", "ami-0199d6df117801fc7"],
      ["us-east-2", "x64", "17", "ami-063af4d9afb2e908d", "ami-0199d6df117801fc7"],
      ["us-east-2", "x64", "18", "ami-063af4d9afb2e908d", "ami-0199d6df117801fc7"],
      ["eu-west-1", "x64", "16", "ami-085cb9014043e3870", "ami-04e410455af2701a7"],
      ["eu-west-1", "x64", "17", "ami-085cb9014043e3870", "ami-04e410455af2701a7"],
      ["eu-west-1", "x64", "18", "ami-085cb9014043e3870", "ami-04e410455af2701a7"],
      ["ap-southeast-2", "x64", "16", "ami-039be95901d14f3f8", "ami-058daa4601bf9bb85"],
      ["ap-southeast-2", "x64", "17", "ami-039be95901d14f3f8", "ami-058daa4601bf9bb85"],
      ["ap-southeast-2", "x64", "18", "ami-039be95901d14f3f8", "ami-058daa4601bf9bb85"],
      ["us-west-2", "arm64", "16", "ami-0bf8cd4daba873da2", "ami-0208e2e5828df2c98"],
      ["us-west-2", "arm64", "17", "ami-0bf8cd4daba873da2", "ami-0208e2e5828df2c98"],
      ["us-west-2", "arm64", "18", "ami-0bf8cd4daba873da2", "ami-0208e2e5828df2c98"],
      ["us-east-1", "arm64", "16", "ami-002e22a4b4ca21f8f", "ami-0ec032eb86708362d"],
      ["us-east-1", "arm64", "17", "ami-002e22a4b4ca21f8f", "ami-0ec032eb86708362d"],
      ["us-east-1", "arm64", "18", "ami-002e22a4b4ca21f8f", "ami-0ec032eb86708362d"],
      ["us-east-2", "arm64", "16", "ami-00f56035200b834c1", "ami-065754213f20865f4"],
      ["us-east-2", "arm64", "17", "ami-00f56035200b834c1", "ami-065754213f20865f4"],
      ["us-east-2", "arm64", "18", "ami-00f56035200b834c1", "ami-065754213f20865f4"],
      ["eu-west-1", "arm64", "16", "ami-0e91b71121c80ed56", "ami-0381f44b045b93d25"],
      ["eu-west-1", "arm64", "17", "ami-0e91b71121c80ed56", "ami-0381f44b045b93d25"],
      ["eu-west-1", "arm64", "18", "ami-0e91b71121c80ed56", "ami-0381f44b045b93d25"],
      ["ap-southeast-2", "arm64", "16", "ami-0706e441141f7caa2", "ami-03380543da666e424"],
      ["ap-southeast-2", "arm64", "17", "ami-0706e441141f7caa2", "ami-03380543da666e424"],
      ["ap-southeast-2", "arm64", "18", "ami-0706e441141f7caa2", "ami-03380543da666e424"]
    ].each do |location_name, arch, pg_version, new_ami, _old_ami|
      from(:pg_aws_ami)
        .where(aws_location_name: location_name, arch: arch, pg_version: pg_version)
        .update(aws_ami_id: new_ami)
    end
  end

  down do
    [
      ["us-west-2", "x64", "16", "ami-07216deeaa235e092", "ami-0f8904e4361eb8be7"],
      ["us-west-2", "x64", "17", "ami-07216deeaa235e092", "ami-0f8904e4361eb8be7"],
      ["us-west-2", "x64", "18", "ami-07216deeaa235e092", "ami-0f8904e4361eb8be7"],
      ["us-east-1", "x64", "16", "ami-05453c5f8b6ee1699", "ami-0baca50c6f0398ccb"],
      ["us-east-1", "x64", "17", "ami-05453c5f8b6ee1699", "ami-0baca50c6f0398ccb"],
      ["us-east-1", "x64", "18", "ami-05453c5f8b6ee1699", "ami-0baca50c6f0398ccb"],
      ["us-east-2", "x64", "16", "ami-063af4d9afb2e908d", "ami-0199d6df117801fc7"],
      ["us-east-2", "x64", "17", "ami-063af4d9afb2e908d", "ami-0199d6df117801fc7"],
      ["us-east-2", "x64", "18", "ami-063af4d9afb2e908d", "ami-0199d6df117801fc7"],
      ["eu-west-1", "x64", "16", "ami-085cb9014043e3870", "ami-04e410455af2701a7"],
      ["eu-west-1", "x64", "17", "ami-085cb9014043e3870", "ami-04e410455af2701a7"],
      ["eu-west-1", "x64", "18", "ami-085cb9014043e3870", "ami-04e410455af2701a7"],
      ["ap-southeast-2", "x64", "16", "ami-039be95901d14f3f8", "ami-058daa4601bf9bb85"],
      ["ap-southeast-2", "x64", "17", "ami-039be95901d14f3f8", "ami-058daa4601bf9bb85"],
      ["ap-southeast-2", "x64", "18", "ami-039be95901d14f3f8", "ami-058daa4601bf9bb85"],
      ["us-west-2", "arm64", "16", "ami-0bf8cd4daba873da2", "ami-0208e2e5828df2c98"],
      ["us-west-2", "arm64", "17", "ami-0bf8cd4daba873da2", "ami-0208e2e5828df2c98"],
      ["us-west-2", "arm64", "18", "ami-0bf8cd4daba873da2", "ami-0208e2e5828df2c98"],
      ["us-east-1", "arm64", "16", "ami-002e22a4b4ca21f8f", "ami-0ec032eb86708362d"],
      ["us-east-1", "arm64", "17", "ami-002e22a4b4ca21f8f", "ami-0ec032eb86708362d"],
      ["us-east-1", "arm64", "18", "ami-002e22a4b4ca21f8f", "ami-0ec032eb86708362d"],
      ["us-east-2", "arm64", "16", "ami-00f56035200b834c1", "ami-065754213f20865f4"],
      ["us-east-2", "arm64", "17", "ami-00f56035200b834c1", "ami-065754213f20865f4"],
      ["us-east-2", "arm64", "18", "ami-00f56035200b834c1", "ami-065754213f20865f4"],
      ["eu-west-1", "arm64", "16", "ami-0e91b71121c80ed56", "ami-0381f44b045b93d25"],
      ["eu-west-1", "arm64", "17", "ami-0e91b71121c80ed56", "ami-0381f44b045b93d25"],
      ["eu-west-1", "arm64", "18", "ami-0e91b71121c80ed56", "ami-0381f44b045b93d25"],
      ["ap-southeast-2", "arm64", "16", "ami-0706e441141f7caa2", "ami-03380543da666e424"],
      ["ap-southeast-2", "arm64", "17", "ami-0706e441141f7caa2", "ami-03380543da666e424"],
      ["ap-southeast-2", "arm64", "18", "ami-0706e441141f7caa2", "ami-03380543da666e424"]
    ].each do |location_name, arch, pg_version, _new_ami, old_ami|
      next if old_ami.to_s.empty?
      from(:pg_aws_ami)
        .where(aws_location_name: location_name, arch: arch, pg_version: pg_version)
        .update(aws_ami_id: old_ami)
    end
  end
end
