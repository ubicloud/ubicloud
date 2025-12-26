module.exports = async ({ exec, semver }, prNumber) => {
  let tagsOutput = "";
  let tagsError = "";
  const options = {
    listeners: {
      stdout: (data) => {
        tagsOutput += data.toString();
      },
      stderr: (data) => {
        tagsError += data.toString();
      },
    },
  };

  await exec.exec("git", ["ls-remote", "--tags", "origin", `*-pr-${prNumber}`], options);
  if (tagsError) {
    throw new Error(tagsError);
  }
  if (tagsOutput.length === 0) {
    console.log("No matching tags found.");
    return {};
  }
  // ls-remote output format: <sha>\trefs/tags/<tag-name>
  // Extract just the tag names
  const tags = tagsOutput.trim().split("\n").map(line => {
    const parts = line.split('\t');
    return parts[1]?.replace('refs/tags/', '') || '';
  }).filter(Boolean);

  // tags are in the format service-name-1.123.0-pr-456
  // we want to collect only the lastest version of each service
  matcher = /^(?<service>[\w-]+)-(?<version>\d+\.\d+\.\d+-pr-\d+)$/;
  let services = {};
  tags.forEach((tag) => {
    const match = matcher.exec(tag);
    if (!match) {
      return;
    }
    const { service, version } = match.groups;
    previousVersion = services[service] || "0.0.0";
    if (semver.gt(version, previousVersion)) {
      services[service] = version;
    }
  });

  // Transform the object into an array of objects so it's compatible with matrix
  return Object.entries(services).map(([service, version]) => ({
    service,
    version,
  }));
};
