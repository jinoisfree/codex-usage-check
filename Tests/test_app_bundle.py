from pathlib import Path
import re
import subprocess
import unittest


class AppBundleTests(unittest.TestCase):
    def test_repository_tracks_no_app_paths(self):
        repository = Path(__file__).parents[1]
        result = subprocess.run(["git", "-C", str(repository), "ls-files", "-z"],
                                check=True, capture_output=True, text=True)
        self.assertFalse([path for path in result.stdout.split("\0") if re.search(r"\.app(/|$)", path)])

    def test_build_template_exists_with_bundle_metadata_and_icon(self):
        repository = Path(__file__).parents[1]
        script = (repository / "build-widget-app.sh").read_text()
        match = re.search(r'^APP_TEMPLATE="\$SCRIPT_DIR/([^"]+)"$', script, re.MULTILINE)
        self.assertIsNotNone(match)
        template = repository / match.group(1)
        self.assertEqual(template, repository / "AppBundle/Template")
        self.assertTrue((template / "Contents/Info.plist").is_file())
        self.assertTrue((template / "Contents/PkgInfo").is_file())
        self.assertTrue((template / "Contents/Resources/CodexUsage.icns").is_file())


if __name__ == "__main__":
    unittest.main()
