// PlayUp Tools - www.playuptools.com

using UnityEngine;
using UnityEditor;
using System.Collections;
using System.IO;
using System.Text;

using System;
using System.Xml;

public class PlayUpMenu: EditorWindow {

	string myLevel = "";
	string myPath = "";
	string myDir = "";
	
	[MenuItem ("PlayUp/Import Level")]
	
	static void  Init () {
		// Get existing open window or if none, make a new one:
		PlayUpMenu window = (PlayUpMenu)EditorWindow.GetWindow (typeof (PlayUpMenu));
		window.Show ();
	}
	
	void OnGUI  () {
		Texture2D texty = AssetDatabase.LoadAssetAtPath("Assets/PlayUp/Editor PlayUp Resources/playup-logo-unity.png", typeof(Texture2D)) as Texture2D; 
		if (texty) GUI.DrawTexture(new Rect(20,0,227, 60), texty); 	
		GUI.BeginGroup (new  Rect (10, 70, 270, 200));
		
		GUILayout.BeginHorizontal (GUILayout.Width(200));
		GUILayout.Space (50);
		if(GUILayout.Button("www.playuptools.com", GUILayout.Width(170))) {
			Application.OpenURL("http://www.playuptools.com");
		}
		GUILayout.EndHorizontal ();
		GUILayout.Space (10);
		if (myLevel != "") {
			GUILayout.Label ("LEVEL SELECTED FOR IMPORT: ", EditorStyles.boldLabel);
			GUILayout.Label (myLevel, EditorStyles.boldLabel);
			GUILayout.Label ("");
			GUILayout.Label ("Click on the Import button to load the level.");
		}
		else {
			GUILayout.Label ("LEVEL SELECTED FOR IMPORT: ", EditorStyles.boldLabel);
			GUILayout.Label ("none", EditorStyles.boldLabel);
			GUILayout.Label ("");
			GUILayout.Label ("Select a level file by clicking the Browse button.");
		}
		GUILayout.BeginHorizontal (GUILayout.Width(200));
	   if(GUILayout.Button("Browse", GUILayout.Width(100))) {
			myPath = Path.GetFullPath(EditorUtility.OpenFilePanel("Choose the Level File", "Assets/PlayUp/Levels/", "lvl"));
		    myLevel = Path.GetFileName(myPath);
			myDir = Path.GetDirectoryName(myPath);
			string[] dirs = myDir.Split('\\');
			bool startTracking = false;
			myDir = "";
			for (int j=0; j<dirs.Length; j++)
			{
				if (startTracking == true){
					myDir = myDir + "/" + dirs[j];
				}
				if (dirs[j] == "Assets"){
					startTracking = true;
					myDir = myDir + dirs[j];
				}
			}
			Debug.Log (dirs.Length);
			Debug.Log(myPath);
			Debug.Log(myLevel);
			Debug.Log (myDir);
	   } 
	   if (myLevel != "") {
		   if(GUILayout.Button("Import", GUILayout.Width(100))) {
				if (myLevel != "") PlayUpImport.FiletoObj(myLevel,myDir);
			   else Debug.Log("You have not yet selected a level file.  Please select a level file by clicking the Browse button.");
		   } 
		}
	GUILayout.EndHorizontal ();
		GUI.EndGroup ();
	}
}