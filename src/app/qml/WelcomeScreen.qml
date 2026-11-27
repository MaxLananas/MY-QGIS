import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.qgis.app

import "components"

Item {
  id: welcomeScreen

  property bool narrowLayout: height < 350 || width < 480
  property real layoutSizeFactor: width > 1200 && height > 880 ? 1.25 : 1

  property real titleFontSize: Application.font.pointSize * 1.3 * layoutSizeFactor
  property real largeFontSize: Application.font.pointSize * 1.1 * layoutSizeFactor
  property real normalFontSize: Application.font.pointSize * layoutSizeFactor
  property real smallFontSize: Application.font.pointSize * 0.95 * layoutSizeFactor
  property real tinyFontSize: Application.font.pointSize * 0.925 * layoutSizeFactor

  width: 2100
  height: 1420

  Material.accent: "#93b023"
  Material.foreground: "#ffffff"

  component ActionPill : Rectangle {
    id: actionPill

    property alias label: actionPillLabel.text
    property bool primary: false
    property bool hovered: false
    signal activated

    height: 26 * layoutSizeFactor
    width: actionPillLabel.implicitWidth + 24
    radius: height / 2
    color: actionPill.hovered ? ( primary ? "#4d8529" : "#f2f7ef" ) : ( primary ? "#589632" : "transparent" )
    border.width: 1
    border.color: primary ? "#589632" : "#93b023"

    Text {
      id: actionPillLabel
      anchors.centerIn: parent
      font.pointSize: tinyFontSize
      font.bold: true
      color: actionPill.primary ? "#ffffff" : "#2f6b24"
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      hoverEnabled: true
      onEntered: actionPill.hovered = true
      onExited: actionPill.hovered = false
      onClicked: actionPill.activated()
    }
  }

  component KeyCap : Rectangle {
    id: keyCap

    property alias label: keyCapLabel.text

    width: keyCapLabel.implicitWidth + 14
    height: 22 * layoutSizeFactor
    radius: 4
    color: "#eef1f4"
    border.width: 1
    border.color: "#d3d9e0"

    Text {
      id: keyCapLabel
      anchors.centerIn: parent
      font.pointSize: tinyFontSize
      font.bold: true
      color: "#3c4653"
    }
  }

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: 20

    Rectangle {
      id: mainCard

      property bool tinyHeight: height < 175
      property bool shortHeight: height < 350

      Layout.fillWidth: true
      Layout.fillHeight: true
      radius: 10
      color: "#002033"
      clip: true

      GridLayout {
        anchors {
          top: parent.top
          left: parent.left
          right: parent.right
          bottom: footer.top
          topMargin: mainCard.shortHeight ? 16 : 20
          leftMargin: 28
          rightMargin: 28
          bottomMargin: 8
        }
        columns: welcomeScreen.narrowLayout ? 1 : 2
        columnSpacing: 20
        rowSpacing: welcomeScreen.narrowLayout ? 0 : 10

        Column {
          Layout.maximumWidth: welcomeScreen.narrowLayout ? parent.width : parent.width * 0.52
          Layout.fillWidth: true
          Layout.preferredHeight: mainCard.shortHeight ? 0 : -1
          Layout.alignment: Qt.AlignTop
          spacing: 10
          clip: true

          Image {
            source: "images/qgis.svg"
            height: welcomeScreen.narrowLayout ? 35 : 50
            width: 160
            fillMode: Image.PreserveAspectFit
            horizontalAlignment: Image.AlignLeft
            smooth: true
            mipmap: true
          }

          Text {
            width: parent.width
            text: qsTr("Spatial without Compromise")
            font.pointSize: normalFontSize
            font.bold: true
            wrapMode: Text.WordWrap

            color: "#e0e9ed"
          }
          
          Rectangle {
            width: parent.width
            height: 1
            color: "#566775"
          }

          // Always-visible entry points: open an existing project from disk
          // (the welcome screen has no other route to the file dialog).
          Row {
            width: parent.width
            spacing: 8

            ActionPill {
              label: qsTr("Open other project…")
              primary: true
              onActivated: {
                welcomeScreenController.openProjectDialog();
                welcomeScreenController.hideScene();
              }
            }

            ActionPill {
              label: qsTr("New blank project")
              onActivated: {
                welcomeScreenController.createBlankProject();
                welcomeScreenController.hideScene();
              }
            }
          }

          // Fast search across recent projects: type a few characters and
          // click a result to open it directly. Read-only by design: this
          // list only opens projects, all management actions stay on the
          // project cards (their menus are index-mapped to the model).
          Column {
            id: projectSearchArea
            width: parent.width
            spacing: 6
            visible: recentProjectsModel.rowCount() > 0

            Rectangle {
              width: parent.width
              height: 34 * layoutSizeFactor
              radius: 6
              color: "#16334a"
              border.width: 1
              border.color: projectSearchField.activeFocus ? "#93b023" : "#566775"

              TextField {
                id: projectSearchField
                anchors.fill: parent
                anchors.margins: 6
                color: "#e0e9ed"
                placeholderText: qsTr("Search recent projects…")
                placeholderTextColor: "#7d93a6"
                font.pointSize: smallFontSize
                background: null
                selectByMouse: true
                verticalAlignment: TextInput.AlignVCenter

                Keys.onEscapePressed: {
                  projectSearchField.text = "";
                  projectSearchField.focus = false;
                }
                Keys.onReturnPressed: {
                  // open the first matching project directly from the keyboard
                  for ( let i = 0; i < recentProjectsModel.rowCount(); ++i )
                  {
                    const firstMatch = matchesList.itemAtIndex( i );
                    if ( firstMatch && firstMatch.isMatch && firstMatch.Exists )
                    {
                      firstMatch.activate();
                      return;
                    }
                  }
                }
              }
            }

            Rectangle {
              width: parent.width
              height: projectSearchField.text.length > 1 ? Math.min( matchesColumn.childrenRect.height + 16, 220 * layoutSizeFactor ) : 0
              visible: height > 0
              radius: 6
              color: "#122a3c"
              border.width: 1
              border.color: "#566775"
              clip: true

              ListView {
                id: matchesList
                anchors.fill: parent
                anchors.margins: 8
                interactive: height >= 220 * layoutSizeFactor
                clip: true
                model: recentProjectsModel

                delegate: Rectangle {
                  id: delegateRoot

                  width: matchesList.width
                  height: isMatch && projectSearchField.text.length > 1 ? 40 * layoutSizeFactor : 0
                  visible: height > 0
                  radius: 4
                  color: matchMouse.containsMouse ? "#1e4563" : "transparent"

                  readonly property bool isMatch: {
                    const query = projectSearchField.text.toLowerCase();
                    if ( query.length <= 1 )
                      return false;
                    const title = ( Title || "" ).toLowerCase();
                    const path = ( ProjectNativePath || ProjectPath || "" ).toLowerCase();
                    return title.includes( query ) || path.includes( query );
                  }

                  ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 6
                    spacing: 1

                    Text {
                      text: Title || ""
                      font.pointSize: smallFontSize
                      font.bold: true
                      color: Exists ? "#e0e9ed" : "#7d93a6"
                      elide: Text.ElideRight
                      Layout.fillWidth: true
                    }

                    Text {
                      text: ( ProjectNativePath || ProjectPath || "" ).replace( /([\\\/])/g, "$1\u200b" )
                      font.pointSize: tinyFontSize
                      color: "#7d93a6"
                      elide: Text.ElideMiddle
                      Layout.fillWidth: true
                    }
                  }

                  function activate() {
                    welcomeScreenController.openProject( ProjectPath );
                    welcomeScreenController.hideScene();
                  }

                  MouseArea {
                    id: matchMouse
                    anchors.fill: parent
                    cursorShape: Exists ? Qt.PointingHandCursor : Qt.ForbiddenCursor
                    hoverEnabled: true
                    onClicked: {
                      if ( !Exists )
                        return;
                      delegateRoot.activate();
                    }
                  }
                }
              }
            }
          }
        }


        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.rowSpan: 2
          spacing: 8

          Item {
            Layout.fillWidth: true
            Layout.preferredHeight: tabBar.implicitHeight

            Rectangle {
              width: parent.width
              height: 1
              color: "#566775"
              anchors.bottom: parent.bottom
            }

            TabBar {
              id: tabBar
              width: parent.width
              background: Item {
                anchors.fill: parent
              }
              clip: true

              TabButton {
                text: qsTr("Recent")
                font.pointSize: largeFontSize
                font.bold: true
                visible: recentProjectsListView.count > 0
                width: recentProjectsListView.count > 0 ? implicitWidth : 0
                background: null
                focusPolicy: Qt.NoFocus
              }
              TabButton {
                text: qsTr("Templates")
                width: implicitWidth
                font.pointSize: largeFontSize
                font.bold: true
                background: null
                focusPolicy: Qt.NoFocus
              }
              TabButton {
                text: qsTr("Learn")
                width: implicitWidth
                font.pointSize: largeFontSize
                font.bold: true
                background: null
                focusPolicy: Qt.NoFocus
              }

              onCurrentIndexChanged: focusCurrentList()

              function focusCurrentList() {
                if (currentIndex === 0) {
                  recentProjectsListView.forceActiveFocus();
                }
                else if (currentIndex === 1) {
                  templateProjectsListView.forceActiveFocus();
                }
              }
            }
          }

          Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ListView {
              id: recentProjectsListView
              anchors.fill: parent
              spacing: 8
              clip: true
              visible: tabBar.currentIndex === 0
              maximumFlickVelocity: 2000

              model: recentProjectsModel

              delegate: ProjectCard {
                width: recentProjectsListView.width - 12
                title: Title || ""
                // Add invisible spaces after slash and backslash characters to help wrapping paths
                subtitle: (ProjectNativePath || ProjectPath || "").replace(/([\\\/])/g,"$1\u200b")
                crs: Crs
                imageSource: PreviewImagePath || ""
                isEnabled: Exists
                isPinned: Pinned
                isSelected: recentProjectsListView.currentIndex === index
                radius: 6

                onClicked: (mouse) => {
                  tabBar.focusCurrentList()
                  recentProjectsListView.currentIndex = index;

                  if (mouse.button === Qt.RightButton) {
                    recentProjectsMenu.projectIndex = index;
                    recentProjectsMenu.projectPinned = Pinned;
                    recentProjectsMenu.projectExists = Exists;
                    recentProjectsMenu.projectHasNativePath = HasNativePath;

                    const point = mapToItem(recentProjectsListView, mouse.x, mouse.y);
                    recentProjectsMenu.popup(point.x, point.y);
                  }
                }

                onDoubleClicked: (mouse) => {
                  if (mouse.button === Qt.LeftButton) {
                    activate();
                  }
                }

                function activate() {
                  if (isEnabled) {
                    welcomeScreenController.openProject(ProjectPath);
                    welcomeScreenController.hideScene();
                    recentProjectsListView.currentIndex = 0;
                  }
                }
              }

              ScrollBar.vertical: CustomScrollBar {
                policy: ScrollBar.AsNeeded
              }
              
              onCountChanged: {
                if (count == 0 && tabBar.currentIndex == 0) {
                  tabBar.currentIndex = 1;
                }
              }

              Keys.onPressed: (event) => {
                if (event.key === Qt.Key_Right) {
                  tabBar.currentIndex = 1;
                  event.accepted = true;
                  return;
                }

                if (!currentItem)
                  return;

                if (event.key === Qt.Key_Enter || event.key === Qt.Key_Return) {
                  currentItem.activate();
                  event.accepted = true;
                }
              }

              Menu {
                id: recentProjectsMenu

                property int projectIndex: 0
                property bool projectPinned: false
                property bool projectExists: false
                property bool projectHasNativePath: false

                background: Rectangle {
                  implicitWidth: 200
                  implicitHeight: recentProjectsMenu.Material.menuItemHeight
                  radius: recentProjectsMenu.Material.roundedScale
                  color: recentProjectsMenu.Material.dialogColor
                  border.color: recentProjectsMenu.Material.listHighlightColor
                  border.width: 1
                }
                
                MenuItem {
                  text: qsTr("Open Project")
                  enabled: recentProjectsMenu.projectExists
                  visible: enabled
                  height: enabled ? implicitHeight : 0
                  onClicked: {
                    const delegate = recentProjectsListView.itemAtIndex( recentProjectsMenu.projectIndex );
                    if ( delegate )
                      delegate.activate();
                  }
                  background: Rectangle {
                    implicitWidth: 200
                    implicitHeight: parent.Material.menuItemHeight
                    color: parent.highlighted ? parent.Material.listHighlightColor : "transparent"
                  }
                }
                MenuItem {
                  text: recentProjectsMenu.projectPinned? qsTr("Unpin from List") : qsTr("Pin to List")
                  onClicked: {
                    if (recentProjectsMenu.projectPinned) {
                      recentProjectsModel.unpinProject(recentProjectsMenu.projectIndex);
                    } else {
                      recentProjectsModel.pinProject(recentProjectsMenu.projectIndex);
                    }
                  }
                  background: Rectangle {
                    implicitWidth: 200
                    implicitHeight: parent.Material.menuItemHeight
                    color: parent.highlighted ? parent.Material.listHighlightColor : "transparent"
                  }
                }
                MenuItem {
                  text: qsTr("Refresh")
                  enabled: !recentProjectsMenu.projectExists
                  visible: enabled
                  height: enabled ? implicitHeight : 0
                  onClicked: {
                    recentProjectsModel.recheckProject(recentProjectsMenu.projectIndex);
                  }
                  background: Rectangle {
                    implicitWidth: 200
                    implicitHeight: parent.Material.menuItemHeight
                    color: parent.highlighted ? parent.Material.listHighlightColor : "transparent"
                  }
                }
                MenuItem {
                  text: qsTr("Open Directory")
                  enabled: recentProjectsMenu.projectExists && recentProjectsMenu.projectHasNativePath
                  visible: enabled
                  height: enabled ? implicitHeight : 0
                  onClicked: {
                    recentProjectsModel.openProject(recentProjectsMenu.projectIndex);
                  }
                  background: Rectangle {
                    implicitWidth: 200
                    implicitHeight: parent.Material.menuItemHeight
                    color: parent.highlighted ? parent.Material.listHighlightColor : "transparent"
                  }
                }
                MenuItem {
                  text: qsTr("Remove from List")
                  onClicked: {
                    recentProjectsModel.removeProject(recentProjectsMenu.projectIndex);
                  }
                  background: Rectangle {
                    implicitWidth: 200
                    implicitHeight: parent.Material.menuItemHeight
                    color: parent.highlighted ? parent.Material.listHighlightColor : "transparent"
                  }
                }
                MenuSeparator {}
                MenuItem {
                  text: qsTr("Clear List…")
                  onClicked: {
                    welcomeScreenController.clearRecentProjects();
                  }
                  background: Rectangle {
                    implicitWidth: 200
                    implicitHeight: parent.Material.menuItemHeight
                    color: parent.highlighted ? parent.Material.listHighlightColor : "transparent"
                  }
                }
              }
            }

            ListView {
              id: templateProjectsListView
              anchors.fill: parent
              spacing: 8
              clip: true
              visible: tabBar.currentIndex === 1
              maximumFlickVelocity: 2000

              model: templateProjectsModel

              // Group the templates by directory: a header is shown each time the
              // section changes between two consecutive projects.
              section.property: "Section"
              section.criteria: ViewSection.FullString
              section.delegate: Item {
                id: sectionHeader
                required property string section

                width: templateProjectsListView.width - 12
                height: section === "" ? 24 : sectionTitle.implicitHeight + 20

                Text {
                  id: sectionTitle
                  visible: sectionHeader.section !== ""
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.topMargin: 8
                  anchors.leftMargin: 4
                  text: sectionHeader.section
                  font.pointSize: smallFontSize
                  font.bold: true
                  color: "#ffffff"
                  elide: Text.ElideMiddle
                }

                Rectangle {
                  width: parent.width
                  height: 1
                  color: "#566775"
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: sectionHeader.section === "" ? 12 : 6
                }
              }

              delegate: ProjectCard {
                width: templateProjectsListView.width - 12
                backgroundColor: CanvasColor || "#ffffff"
                title: Title || ""
                subtitle: Crs || ""
                imageSource: {
                  switch (Type) {
                  case TemplateProjectsModel.TemplateType.Blank:
                    return "";
                  case TemplateProjectsModel.TemplateType.Basemap:
                    return "../images/basemap.jpg";
                  default:
                    return PreviewImagePath || "";
                  }
                }
                isSelected: templateProjectsListView.currentIndex === index
                radius: 6

                onClicked: (mouse) => {
                  tabBar.focusCurrentList()
                  templateProjectsListView.currentIndex = index;

                  if (mouse.button === Qt.RightButton) {
                    templateProjectsMenu.templateIndex = index;
                    templateProjectsMenu.templateDeletable = ( Type === TemplateProjectsModel.TemplateType.File && Writable );

                    const point = mapToItem(templateProjectsListView, mouse.x, mouse.y);
                    templateProjectsMenu.popup(point.x, point.y);
                  }
                }

                onDoubleClicked: (mouse) => {
                  if (mouse.button === Qt.LeftButton) {
                    activate();
                  }
                }

                function activate() {
                  switch (Type) {
                  case TemplateProjectsModel.TemplateType.Blank:
                    welcomeScreenController.createBlankProject(); //#spellok
                    welcomeScreenController.hideScene();
                    return;
                  case TemplateProjectsModel.TemplateType.Basemap:
                    welcomeScreenController.createProjectFromBasemap();
                    welcomeScreenController.hideScene();
                    return;
                  default:
                    welcomeScreenController.createProjectFromTemplate(TemplateNativePath || ""); //#spellok
                    welcomeScreenController.hideScene();
                    return;
                  }
                }
              }

              ScrollBar.vertical: CustomScrollBar {
                policy: ScrollBar.AsNeeded
              }

              Keys.onPressed: (event) => {
                if (event.key === Qt.Key_Left && recentProjectsListView.count > 0) {
                  tabBar.currentIndex = 0;
                  event.accepted = true;
                  return;
                }

                if (!currentItem)
                  return;

                if (event.key === Qt.Key_Enter || event.key === Qt.Key_Return) {
                  currentItem.activate();
                  event.accepted = true;
                }
              }

              Menu {
                id: templateProjectsMenu

                property int templateIndex: 0
                property bool templateDeletable: false

                background: Rectangle {
                  implicitWidth: 200
                  implicitHeight: templateProjectsMenu.Material.menuItemHeight
                  radius: templateProjectsMenu.Material.roundedScale
                  color: templateProjectsMenu.Material.dialogColor
                  border.color: templateProjectsMenu.Material.listHighlightColor
                  border.width: 1
                }

                MenuItem {
                  text: qsTr("Use Template")
                  onClicked: {
                    const delegate = templateProjectsListView.itemAtIndex( templateProjectsMenu.templateIndex );
                    if ( delegate )
                      delegate.activate();
                  }
                  background: Rectangle {
                    implicitWidth: 200
                    implicitHeight: parent.Material.menuItemHeight
                    color: parent.highlighted ? parent.Material.listHighlightColor : "transparent"
                  }
                }

                MenuItem {
                  text: qsTr("Delete Template…")
                  enabled: templateProjectsMenu.templateDeletable
                  visible: enabled
                  height: enabled ? implicitHeight : 0
                  onClicked: {
                    welcomeScreenController.removeTemplateProject(templateProjectsMenu.templateIndex)
                  }
                  background: Rectangle {
                    implicitWidth: 200
                    implicitHeight: parent.Material.menuItemHeight
                    color: parent.highlighted ? parent.Material.listHighlightColor : "transparent"
                  }
                }
              }
            }

            ScrollView {
              id: learnScrollView
              anchors.fill: parent
              clip: true
              visible: tabBar.currentIndex === 2
              contentWidth: learnLayout.width
              contentHeight: learnLayout.height
              rightPadding: 12

              ScrollBar.vertical: CustomScrollBar {
                policy: ScrollBar.AsNeeded
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.right: parent.right
              }

              ColumnLayout {
                id: learnLayout
                width: learnScrollView.width - learnScrollView.rightPadding
                spacing: 12

                Rectangle {
                  Layout.preferredWidth: parent.width
                  Layout.preferredHeight: getStartedColumn.childrenRect.height + 32
                  radius: 6
                  color: "#ffffff"

                  ColumnLayout {
                    id: getStartedColumn
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 10

                    Text {
                      text: qsTr("Get started in five minutes")
                      font.pointSize: normalFontSize
                      font.bold: true
                      color: "black"
                    }

                    RowLayout {
                      Layout.fillWidth: true
                      spacing: 10

                      Rectangle {
                        width: 22 * layoutSizeFactor
                        height: 22 * layoutSizeFactor
                        radius: height / 2
                        color: "#589632"

                        Text {
                          anchors.centerIn: parent
                          text: "1"
                          font.pointSize: tinyFontSize
                          font.bold: true
                          color: "#ffffff"
                        }
                      }

                      Text {
                        Layout.fillWidth: true
                        text: qsTr("Create a project — start from a blank canvas or build one around an online basemap.")
                        font.pointSize: smallFontSize
                        color: "black"
                        wrapMode: Text.WordWrap
                      }
                    }

                    RowLayout {
                      spacing: 8

                      ActionPill {
                        label: qsTr("New blank project")
                        primary: true
                        onActivated: {
                          welcomeScreenController.createBlankProject();
                          welcomeScreenController.hideScene();
                        }
                      }

                      ActionPill {
                        label: qsTr("New project from a basemap")
                        onActivated: {
                          welcomeScreenController.createProjectFromBasemap();
                          welcomeScreenController.hideScene();
                        }
                      }
                    }

                    RowLayout {
                      Layout.fillWidth: true
                      spacing: 10

                      Rectangle {
                        width: 22 * layoutSizeFactor
                        height: 22 * layoutSizeFactor
                        radius: height / 2
                        color: "#589632"

                        Text {
                          anchors.centerIn: parent
                          text: "2"
                          font.pointSize: tinyFontSize
                          font.bold: true
                          color: "#ffffff"
                        }
                      }

                      Text {
                        Layout.fillWidth: true
                        text: qsTr("Add your data — drag & drop GeoPackage, shapefile or CSV files onto the map canvas, or use Layer ▸ Add Layer.")
                        font.pointSize: smallFontSize
                        color: "black"
                        wrapMode: Text.WordWrap
                      }
                    }

                    RowLayout {
                      Layout.fillWidth: true
                      spacing: 10

                      Rectangle {
                        width: 22 * layoutSizeFactor
                        height: 22 * layoutSizeFactor
                        radius: height / 2
                        color: "#589632"

                        Text {
                          anchors.centerIn: parent
                          text: "3"
                          font.pointSize: tinyFontSize
                          font.bold: true
                          color: "#ffffff"
                        }
                      }

                      Text {
                        Layout.fillWidth: true
                        text: qsTr("Style your layers — double-click a layer in the Layers panel to open the layer styling panel.")
                        font.pointSize: smallFontSize
                        color: "black"
                        wrapMode: Text.WordWrap
                      }
                    }

                    RowLayout {
                      Layout.fillWidth: true
                      spacing: 10

                      Rectangle {
                        width: 22 * layoutSizeFactor
                        height: 22 * layoutSizeFactor
                        radius: height / 2
                        color: "#589632"

                        Text {
                          anchors.centerIn: parent
                          text: "4"
                          font.pointSize: tinyFontSize
                          font.bold: true
                          color: "#ffffff"
                        }
                      }

                      Text {
                        Layout.fillWidth: true
                        text: qsTr("Save your project — Ctrl+S keeps layers, styles and settings together in a single .qgz file.")
                        font.pointSize: smallFontSize
                        color: "black"
                        wrapMode: Text.WordWrap
                      }
                    }
                  }
                }

                Rectangle {
                  Layout.preferredWidth: parent.width
                  Layout.preferredHeight: shortcutsColumn.childrenRect.height + 32
                  radius: 6
                  color: "#ffffff"

                  ColumnLayout {
                    id: shortcutsColumn
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 10

                    Text {
                      text: qsTr("Essential shortcuts")
                      font.pointSize: normalFontSize
                      font.bold: true
                      color: "black"
                    }

                    RowLayout {
                      spacing: 8

                      KeyCap { label: "Ctrl+K" }

                      Text {
                        Layout.fillWidth: true
                        text: qsTr("Search projects, layers, algorithms and commands with the locator")
                        font.pointSize: smallFontSize
                        color: "black"
                        wrapMode: Text.WordWrap
                      }
                    }

                    RowLayout {
                      spacing: 8

                      KeyCap { label: "Ctrl+N" }
                      KeyCap { label: "Ctrl+O" }
                      KeyCap { label: "Ctrl+S" }

                      Text {
                        Layout.fillWidth: true
                        text: qsTr("New, open and save projects")
                        font.pointSize: smallFontSize
                        color: "black"
                        wrapMode: Text.WordWrap
                      }
                    }

                    RowLayout {
                      spacing: 8

                      KeyCap { label: "Ctrl++" }
                      KeyCap { label: "Ctrl+−" }
                      KeyCap { label: "Ctrl+Shift+F" }

                      Text {
                        Layout.fillWidth: true
                        text: qsTr("Zoom in, zoom out and zoom to the full extent of your data")
                        font.pointSize: smallFontSize
                        color: "black"
                        wrapMode: Text.WordWrap
                      }
                    }
                  }
                }

                Rectangle {
                  Layout.preferredWidth: parent.width
                  Layout.preferredHeight: goFurtherColumn.childrenRect.height + 32
                  radius: 6
                  color: "#ffffff"

                  ColumnLayout {
                    id: goFurtherColumn
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 10

                    Text {
                      text: qsTr("Go further")
                      font.pointSize: normalFontSize
                      font.bold: true
                      color: "black"
                    }

                    RowLayout {
                      spacing: 8

                      ActionPill {
                        label: qsTr("User manual")
                        primary: true
                        onActivated: {
                          welcomeScreenController.openUserManual();
                        }
                      }

                      ActionPill {
                        label: qsTr("Tutorials")
                        onActivated: {
                          Qt.openUrlExternally("https://docs.qgis.org/latest/en/docs/training_manual/");
                        }
                      }

                      ActionPill {
                        label: qsTr("What's new")
                        onActivated: {
                          Qt.openUrlExternally("https://qgis.org/project/overview/");
                        }
                      }

                      ActionPill {
                        label: qsTr("Community help")
                        onActivated: {
                          Qt.openUrlExternally("https://gis.stackexchange.com/");
                        }
                      }
                    }

                    RowLayout {
                      spacing: 8

                      ActionPill {
                        label: qsTr("Keyboard shortcuts…")
                        onActivated: {
                          welcomeScreenController.openKeyboardShortcuts();
                        }
                      }

                      ActionPill {
                        label: qsTr("Report an issue")
                        onActivated: {
                          welcomeScreenController.reportIssue();
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }

        ColumnLayout {
          id: welcomeNewsLayout
          Layout.maximumWidth: parent.width * 0.52
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: 12
          visible: !welcomeScreen.narrowLayout

          RowLayout {
            Layout.fillWidth: true
            spacing: 6

            Text {
              Layout.fillWidth: true
              text: newsSwitch.checked && newsListView.count != 0 ? qsTr("Latest news") : qsTr("Welcome to QGIS!")
              font.pointSize: titleFontSize
              font.bold: true
              color: "#ffffff"
              elide: Text.ElideRight
            }

            BusyIndicator {
              Layout.preferredWidth: 28
              Layout.preferredHeight: 28
              running: newsFeedParser.isFetching
            }

            Rectangle {
              id: newsSwitchBackground
              Layout.rightMargin: 12
              Layout.preferredWidth: newsSwitchText.width + 40
              height: 28
              radius: 14

              gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop {
                  position: 0.0
                  color: newsSwitch.checked ? "#589632" : "#333333"
                }
                GradientStop {
                  position: 1.0
                  color: newsSwitch.checked ? "#93b023" : "#ffffff"
                }
              }

              Text {
                id: newsSwitchText
                x: newsSwitch.checked ? 10 : parent.width - width - 10
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("News")
                font.pointSize: tinyFontSize
                font.bold: true
                color: newsSwitch.checked ? "#ffffff" : "#666666"
              }

              Rectangle {
                id: switchHandle
                width: 22
                height: 22
                radius: 11
                color: "#ffffff"
                anchors.verticalCenter: parent.verticalCenter
                x: newsSwitch.checked ? parent.width - width - 3 : 3

                Behavior on x {
                  NumberAnimation {
                    duration: 150
                  }
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  newsFeedParser.enabled = !newsFeedParser.enabled
                  if (newsFeedParser.enabled) {
                    newsFeedParser.fetch();
                  }
                }
              }

              Switch {
                id: newsSwitch
                visible: false
                checked: newsFeedParser.enabled
              }
            }
          }

          ScrollView {
            id: welcomeView
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !newsSwitch.checked || newsListView.count == 0
            contentWidth: welcomeLayout.width
            contentHeight: welcomeLayout.height
            rightPadding: 12
            clip: true

            ScrollBar.vertical: CustomScrollBar {
              policy: ScrollBar.AsNeeded
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              anchors.right: parent.right
            }
            
            ColumnLayout {
              id: welcomeLayout
              width: welcomeNewsLayout.width - welcomeView.rightPadding
              spacing: 12

              Rectangle {
                Layout.preferredWidth: parent.width
                Layout.preferredHeight: firstRunColumn.childrenRect.height + 32
                radius: 6
                color: "#ffffff"
                visible: firstRunGuide && !newsSwitch.checked

                ColumnLayout {
                  id: firstRunColumn
                  anchors.fill: parent
                  anchors.margins: 16
                  spacing: 10

                  Text {
                    text: qsTr("New to QGIS?")
                    font.pointSize: normalFontSize
                    font.bold: true
                    color: "black"
                  }

                  Text {
                    Layout.fillWidth: true
                    text: qsTr("Drag & drop your data onto the map, double-click a layer to style it, and press Ctrl+K to search everything. Take the quick tour to learn the essentials.")
                    font.pointSize: smallFontSize
                    color: "black"
                    wrapMode: Text.WordWrap
                    lineHeight: 1.2
                  }

                  RowLayout {
                    spacing: 8

                    ActionPill {
                      label: qsTr("Show me around")
                      primary: true
                      onActivated: {
                        tabBar.currentIndex = 2;
                      }
                    }

                    ActionPill {
                      label: qsTr("New blank project")
                      onActivated: {
                        welcomeScreenController.createBlankProject();
                        welcomeScreenController.hideScene();
                      }
                    }
                  }
                }
              }

              Rectangle {
                Layout.preferredWidth: parent.width
                Layout.preferredHeight: welcomeDescription.contentHeight + 32
                radius: 6
                color: "#ffffff"

                Text {
                  id: welcomeDescription
                  anchors.fill: parent
                  anchors.margins: 16
                  text: qsTr("The free and open-source geographic information system that empowers users worldwide to create, edit, visualize, analyze, and share geospatial data. Whether you're a beginner or a seasoned GIS expert, QGIS gives you the tools to turn spatial data into impactful maps and insights. Join our vibrant global community and start exploring the world through the power of open-source geospatial technology.")
                  font.pointSize: smallFontSize
                  color: "black"
                  wrapMode: Text.WordWrap
                  lineHeight: 1.3
                }
              }

              Rectangle {
                Layout.preferredWidth: parent.width
                Layout.preferredHeight: stayUpdateLayout.childrenRect.height + 32
                radius: 6
                color: "#ffffff"
                visible: !newsSwitch.checked

                ColumnLayout {
                  id: stayUpdateLayout
                  anchors.fill: parent
                  anchors.margins: 16
                  spacing: 10

                  Text {
                    text: qsTr("Stay up to date!")
                    font.pointSize: normalFontSize
                    font.bold: true
                    color: "black"
                  }

                  Text {
                    Layout.fillWidth: true
                    text: qsTr("Would you like to enable the QGIS news feed to stay updated on new features, releases, and community highlights?")
                    font.pointSize: smallFontSize
                    color: "black"
                    wrapMode: Text.WordWrap
                  }

                  Rectangle {
                    width: enableNewsText.implicitWidth + 24
                    height: 24 * layoutSizeFactor
                    radius: height / 2
                    color: "transparent"
                    border.width: 1
                    border.color: "#93b023"

                    Text {
                      id: enableNewsText
                      anchors.centerIn: parent
                      text: qsTr("Enable news feed")
                      font.pointSize: tinyFontSize
                      color: "black"
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      hoverEnabled: true
                      onClicked: {
                        newsFeedParser.enabled = true;
                        newsFeedParser.fetch();
                      }
                    }
                  }
                }
              }
            }
          }

          ListView {
            id: newsListView
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 12
            clip: true
            visible: newsSwitch.checked

            model: newsFeedModel

            delegate: NewsCard {
              radius: 6
              width: newsListView.width - 12
              title: Title
              description: Content
              imageSource: ImageUrl
              showCloseButton: true
              showLink: Link != ""

              onReadMoreClicked: {
                Qt.openUrlExternally(Link);
              }
              
              onCloseClicked: {
                newsFeedParser.dismissEntry(Key);
              }
            }

            ScrollBar.vertical: CustomScrollBar {
              policy: ScrollBar.AsNeeded
            }
          }
        }
      }

      Rectangle {
        width: parent.width
        height: 1
        color: "#566775"
        anchors {
          bottom: footer.top
          left: parent.left
          right: parent.right
          leftMargin: 28
          rightMargin: 28
        }
      }

      FooterBar {
        id: footer
        anchors {
          left: parent.left
          leftMargin: 28
          right: parent.right
          rightMargin: 28
          bottom: parent.bottom
          bottomMargin: 0
        }
        height: mainCard.tinyHeight ? 0 : implicitHeight

        onSupportClicked: {
          Qt.openUrlExternally("https://www.qgis.org/funding/donate/")
        }

        onDocsClicked: {
          Qt.openUrlExternally("https://docs.qgis.org/")
        }

        onWebsiteClicked: {
          Qt.openUrlExternally("https://www.qgis.org/")
        }
      }
      
      RoundButton {
        id: closeButton
        anchors{
          top: parent.top
          right: parent.right
          margins: 5
        }
      
        background: Rectangle {
          implicitWidth: closeButton.Material.buttonHeight
          implicitHeight: closeButton.Material.buttonHeight

          radius: closeButton.radius
          color: closeButton.Material.buttonColor(closeButton.Material.theme, closeButton.Material.background,
              closeButton.Material.accent, closeButton.enabled, closeButton.flat, closeButton.highlighted, false)

          Rectangle {
            width: parent.width
            height: parent.height
            radius: closeButton.radius
            visible: enabled && (closeButton.hovered || closeButton.visualFocus)
            color: "#33ffffff"
          }

          Rectangle {
            width: parent.width
            height: parent.height
            radius: closeButton.radius
            visible: closeButton.down
            color: "#33ffffff"
          }
        }

        flat: true
        icon.source: "images/close.svg"
        icon.color: "white"
        icon.width: 20
        icon.height: 20
        onClicked: {
          welcomeScreenController.hideScene();
        }
      }
    }

    UpdateNotificationBar {
      id: pluginsUpdateBar
      Layout.fillWidth: true
      Layout.preferredHeight: 54
      radius: mainCard.radius
      visible: false
      color: "#ed7913"

      onInstallClicked: {
        visible = false;
        welcomeScreenController.showPluginManager();
      }
    }

    UpdateNotificationBar {
      id: qgisUpdateBar
      Layout.fillWidth: true
      Layout.preferredHeight: 54
      radius: mainCard.radius
      visible: false
      color: mainCard.color

      onInstallClicked: {
        Qt.openUrlExternally("https://download.qgis.org/")
      }
    }
  }
  
  DropArea {
    anchors.fill: parent

    onDropped: drop => {
      let formatsData = {};
      for(const format of drop.formats) {
        formatsData[format] = drop.getDataAsArrayBuffer(format);
      }
      welcomeScreenController.forwardDrop(drop.text, drop.urls, formatsData);
    }
  }
  
  Connections {
    target: welcomeScreenController
    
    function onNewVersionAvailable(versionString) {
      qgisUpdateBar.message = qsTr("QGIS %1 is out!").arg(versionString);
      qgisUpdateBar.visible = true;
    }
    
    function onPluginUpdatesAvailable(plugins) {
      pluginsUpdateBar.message = qsTr("The following plugin(s) have available updates: %1", "", plugins.length).arg(plugins.join(", "));
      pluginsUpdateBar.visible = true;
    }

    function onWelcomeScreenShown() {
      tabBar.focusCurrentList();
    }
  }

  Component.onCompleted: {
    tabBar.currentIndex = firstRunGuide ? 2 : ( recentProjectsListView.count > 0 ? 0 : 1 );
    if (newsFeedParser.enabled) {
      newsFeedParser.fetch();
    }
  }
}
